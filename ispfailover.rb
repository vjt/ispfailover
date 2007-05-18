require 'rubygems'
require 'simplehashwithindifferentaccess'
require 'facets/core/array/shuffle'
require 'resolv-replace'
require 'bindping'
require 'thread'
require 'yaml'
require 'iproute'
require 'syslog'

Thread.abort_on_exception = true

module ISPFailOver
  Mutex = ::Mutex.new
  Cond = ::ConditionVariable.new
  $slot = nil

  class Master
    def initialize
      Syslog.open $0, Syslog::LOG_NDELAY|Syslog::LOG_PID, Syslog::LOG_DAEMON

      @conf = YAML.load File.read('ispfailover.yml')
      @master = Thread.new &self.master_proc
      @linkmon = Thread.new &self.linkmon_proc
      @monitors = {}
      (IPRoute.links.keys & @conf[:interfaces].keys).each do |interface|
        spawn(interface)
      end
      @master.join
    end

    def spawn(interface)
      Mutex.synchronize do
        conf = @conf[:interfaces][interface].dup
        conf[:interface] = interface

        probe = @conf[:probe].dup
        while (local = IPRoute.local_host interface).nil?
          Syslog.info "waiting for #{interface} to acquire remote address"
          sleep rand
        end

        probe[:local] = local
        @monitors[interface] = Monitor.new(conf, probe)
      end
    end

    def kill(interface)
      Mutex.synchronize do
        @monitors[interface].thread.kill
        @monitors.delete interface
      end
    end

    def active?(interface)
      Mutex.synchronize do
        !@monitors[interface].nil?
      end
    end

    def killall
      @master.kill
      @monitors.each { |m| m.thread.kill }
    end

    protected
    def master_proc
      proc {
        loop do
          Mutex.synchronize do
            Cond.wait(Mutex)
            update_rib $slot
          end
        end
      }
    end

    require 'ruby-debug'
    Debugger.start
    def linkmon_proc
      proc {
        IPRoute.foreach_link_change do |action, (iface, id)|
          provider = @conf[:interfaces][iface][:provider]
          if action == :delete
            Syslog.warning "#{provider} interface #{iface} went down, killing worker thread"
            kill(iface)
            @monitors.values.each { |mon| update_rib mon.conf }
          elsif !active?(iface)
            Syslog.info "#{provider} interface #{iface} is back up, restarting worker thread"
            spawn(iface)
          end
        end
      }
    end

    def update_rib(conf)
      if conf[:status] == :alive
        IPRoute.add_nexthop conf[:gateway], conf[:interface], conf[:weight]
      else
        IPRoute.del_nexthop conf[:gateway], conf[:interface]
      end
    end
  end

  class Monitor
    def initialize(conf, probe)
      sleep 0.4 # give threads a bit of skew
      @conf = conf
      @probe = probe
      @thread = Thread.new &self
    end
    attr_reader :thread, :conf

    def to_proc
      proc {
        Syslog.info "#{@conf[:provider]} thread started."

        loop do
          status = probe
          if status != @conf[:status]
            @conf[:status] = status
            signal
          end
          wait
        end
      }
    end

    def probe
      @probe[:hosts].shuffle.each do |host|
        if @conf[:status] == :dead
          IPRoute.with_temp_route(host, @conf[:gateway], @conf[:interface]) do
            return :alive if ping(host)
          end
          wait
        elsif ping(host)
          return :alive
        end
      end
      :dead
    end

    def ping host
      Ping.probe host, @probe[:service], @probe[:local], @probe[:timeout]
    end

    def signal
      Mutex.synchronize do
        Syslog.warning "#{@conf[:provider]} changed state to #{@conf[:status]}"
        $slot = @conf

        Cond.signal
      end
    end

    def wait
      threshold = @conf[:status] == :active ? 30 : 0
      sleep @probe[:interval] + threshold
    end
  end
end

if __FILE__ == $0
  ISPFailOver::Master.new
end
