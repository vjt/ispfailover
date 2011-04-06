require 'rubygems'
require 'facets/core/array/to_h'
require 'thread'

#module Kernel; alias :old_exec :`; def `(cmd); Syslog.info("running #{cmd}"); old_exec cmd; end; end

module IPRoute
  Mutex = ::Mutex.new

  class << self
    def default_route
      `ip -4 route ls 0.0.0.0/0`.strip
    end

    def local_host(interface)
      `ip -4 -o addr ls dev #{interface} scope global`.scan(/inet ((\d+\.){3}\d+)/).flatten.first
    end

    # There's a lot to beautify, here ;)
    #
    def with_temp_route(dest, gw, iface)
      Mutex.synchronize do
        begin
          add_route dest, gw, iface, 'monitor'
          `ip -4 rule add to #{dest} lookup monitor`
          yield

        ensure
          `ip -4 rule del to #{dest} lookup monitor`
          del_route dest, gw, iface, 'monitor'
        end
      end
    end

    def add_route(dest, gw, iface, table = 'main')
      `ip -4 route add #{dest} via #{gw} dev #{iface} table #{table}`
    end

    def add_src_route(dest, gw, iface, src, table = 'main')
      `ip -4 route add #{dest} via #{gw} dev #{iface} src #{src} table #{table}`
    end

    def del_route(dest, gw, iface, table = 'main')
      `ip -4 route del #{dest} via #{gw} dev #{iface} table #{table}`
    end

    def add_rule(network, iface, table)
      `ip -4 rule add from #{network} lookup #{table}` unless \
        exists?(:rule, "from #{network} lookup #{table}")

      `ip -4 rule add to #{network} dev #{iface} lookup #{table}` unless \
        exists?(:rule, "from all to #{network} iif #{iface} lookup #{table}")
    end

    def del_rule(network, iface, table)
      `ip -4 rule del from #{network} lookup #{table}`
      `ip -4 rule del to #{network} dev #{iface} lookup #{table}`
    end

    def add_nexthop(gw, iface, table, wgt = 1)
#      Syslog.info("add_nexthop(#{gw}, #{iface}, #{wgt})")
      Mutex.synchronize do
        @wgts ||= {}
	@wgts[iface] ||= wgt

	add_route :default, gw, iface, table

        if default_route.nil? || default_route.empty?
          `ip -4 route add default #{nexthop(gw, iface, wgt)}`
        else
          hops = nexthops(iface).push(nexthop(gw, iface, wgt))
          `ip -4 route change default #{hops.join ' '}`
        end
      end
    end

    def del_nexthop(gw, iface, table)
#      Syslog.info("del_nexthop(#{gw}, #{iface})")
      Mutex.synchronize do
        unless (hops = nexthops(iface)).empty?
          `ip -4 route change default #{hops.join ' '}`
          `ip -4 route flush cache dev #{iface}`
        else
          `ip -4 route del default`
          `ip -4 route flush cache`
        end

	del_route :default, gw, iface, table
      end
    end

    def nexthops(skip = nil)
      hops =
        if default_route.include? "\n"
          default_route.split("\n").reject! { |x| x.strip! == 'default' }
        else
          route = default_route.sub(/^default/, 'nexthop')
	  iface = route.scan(/dev (\w+)/).flatten.first
	  if @wgts && @wgts[iface]
	    route << " weight #{@wgts[iface]}"
	  end
	  [route]
        end

      hops.reject! { |x| x =~ /#{skip}/ } if skip
      hops
    end

    def links
      `ip -o link ls`.split("\n").map! { |link| parse_link link }.to_h
    end

    def foreach_link_change
      File.popen('ip -o monitor link') do |io|
        while line = io.readline
          iface, state = parse_link line
          yield iface, state
        end
      end
    rescue
      Process.wait(-1, Process::WNOHANG)
      retry
    end

    protected
    def nexthop(gw, iface, wgt)
      "nexthop via #{gw} dev #{iface} weight #{wgt}"
    end

    def parse_link(link)
      puts link
      iface, state = link.scan(/^(?:Deleted )?\d+: ([\w\d]+): .*state (DOWN|UP|UNKNOWN)/).first

      state = state.downcase.to_sym
      if state == :unknown and iface =~ /^ppp/
        state = :up
      end

      return [iface, state]
    end

    def exists?(kind, arguments)
      `ip #{kind} ls`.scan(/\t([^\n]+) *\n/).
        flatten.grep(/#{arguments}/).size > 0
    end

    alias :run :`
    def `(cmd)
      Syslog.info cmd
      run cmd
    end
  end
end
