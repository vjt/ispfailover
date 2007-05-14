require 'simplehashwithindifferentaccess'
#require 'facets/more/opencascade'
require 'resolv-replace'
require 'bindping'
require 'thread'
require 'yaml'
require 'iproute'

Thread.abort_on_exception = true

module ISPFailOver
  SyncMutex = ::Mutex.new
  SyncCond = ::ConditionVariable.new
  $slot = nil

  RtMutex = ::Mutex.new

  class Master
    def initialize
      @conf = YAML.load(File.read('ispfailover.yml'))
      @master = Thread.new &self.to_proc
      @threads = @conf[:providers].map do |name, conf|
        probe = @conf[:probe].dup
        probe[:local] = IPRoute.local_host conf[:interface]
        Thread.new &Monitor.new(name, conf, probe).to_proc
      end
      @master.join
    end

    def kill
      @master.kill
      @threads.each { |t| t.kill }
    end

    def to_proc
      proc {
        loop do
          SyncMutex.synchronize do
            SyncCond.wait(SyncMutex)

            monitor = $slot
            conf = @conf[:providers][monitor.name]
            if monitor.status == :alive
              IPRoute.add_nexthop conf[:gateway], conf[:interface], conf[:weight]
            else
              IPRoute.del_nexthop conf[:gateway], conf[:interface], conf[:weight]
            end
          end
        end
      }
    end
  end

  class Monitor
    def initialize(name, conf, probe_conf)
      @name = name
      @conf = conf
      @probe = probe_conf
      @status = probe
    end

    attr_reader :name, :status

    def to_proc
      proc {
        loop do
          wait
          status = probe
          if status != @status
            @status = status
            signal
          end

        end
      }
    end

    def probe
      with_temp_route(@probe[:host], @conf[:gateway], @conf[:interface]) do
        if Ping.probe @probe[:host], @probe[:service], @probe[:local], @probe[:timeout]
          puts "#{name} is alive!"
          :alive
        else
          puts "#{name} is dead."
          :dead
        end
      end
    end

    def with_temp_route(host, gw, iface)
      ret = nil
      RtMutex.synchronize do
        IPRoute.add_route host, gw, iface
        ret = yield
        IPRoute.del_route host, gw, iface
      end
      ret
    end

    def signal
      SyncMutex.synchronize do
        $slot = self
        SyncCond.signal
      end
    end

    def wait
      sleep @probe[:interval]
    end
  end
end

if __FILE__ == $0
  ISPFailOver::Master.new
end
