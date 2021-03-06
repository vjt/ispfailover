require 'rubygems'
require 'simplehashwithindifferentaccess'
require 'facets/core/array/shuffle'
require 'resolv'
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
      @conf[:probe][:hosts] = ('a'..'m').map { |x| Resolv.getaddress("#{x}.root-servers.net") }.compact rescue File.read('rootservers.txt').split("\n")
      @conf[:probe][:service] = 53
      Syslog.info "initializing, loaded #{@conf[:probe][:hosts].size} probe hosts"

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
          Syslog.info "waiting for #{interface} to acquire address"
          sleep(rand + 1)
        end

        probe[:local] = local
        @monitors[interface] = Monitor.new(conf, probe)
      end
    end

    def kill(interface)
      Mutex.synchronize do
        @monitors[interface].down!
        @monitors.values.each { |mon| update_rib mon.conf }
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
      @monitors.each { |m| m.down! }
    end

    protected
    def master_proc
      proc {
	Mutex.synchronize do
          loop do
            Cond.wait(Mutex)
#	    Syslog.info "signal received from #{$slot.inspect}"
            update_rib $slot
#	    Syslog.info "signal dispatched for #{$slot.inspect}"
          end
        end
      }
    end

    def linkmon_proc
      proc {
        IPRoute.foreach_link_change do |iface, state|
          provider = @conf[:interfaces][iface][:provider] rescue next

          if state == :down && active?(iface)
            Syslog.warning "#{provider} interface #{iface} went down, killing worker thread"
            kill(iface)

          elsif state == :up && !active?(iface)
            Syslog.info "#{provider} interface #{iface} is back up, restarting worker thread"
            spawn(iface)

          end
        end
      }
    end

    # FIXME this method is simply unreadable and sucky
    def update_rib(conf)
      if conf[:status] == :alive
        IPRoute.add_nexthop conf[:gateway], conf[:interface], conf[:provider], conf[:weight]
        IPRoute.add_src_route conf[:network], conf[:gateway], conf[:interface], conf[:address], conf[:provider]
        IPRoute.add_rule conf[:network], conf[:interface], conf[:provider]
      else
        IPRoute.del_nexthop conf[:gateway], conf[:interface], conf[:provider]
        IPRoute.del_route conf[:network], conf[:gateway], conf[:interface], conf[:provider]
        IPRoute.del_rule conf[:network], conf[:interface], conf[:provider]
      end
    end
  end

  class Monitor
    def initialize(conf, probe)
      @conf = conf
      @probe = probe
      @thread = Thread.new &self
    end
    attr_reader :conf

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
      @probe[:hosts].shuffle[0..3].each do |host|
        if @conf[:status] == :dead or @conf[:status].nil?
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
      sleep((@conf[:status] == :alive) ? @probe[:interval] : @probe[:neg_interval])
    end

    def down!
      @thread.kill
      @conf[:status] = :dead
    end
  end
end

if __FILE__ == $0
  ISPFailOver::Master.new
end
