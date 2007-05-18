require 'rubygems'
require 'facets/core/array/to_h'
require 'thread'

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

    def del_route(dest, gw, iface, table = 'main')
      `ip -4 route del #{dest} via #{gw} dev #{iface} table #{table}`
    end

    def add_nexthop(gw, iface, wgt = 1)
      Mutex.synchronize do
        if default_route.nil? || default_route.empty?
          `ip -4 route add default #{nexthop(gw, iface, wgt)}`
        else
          hops = nexthops(iface).push(nexthop(gw, iface, wgt))
          `ip -4 route change default #{hops.join ' '}`
        end
      end
    end

    def del_nexthop(gw, iface)
      Mutex.synchronize do
        unless (hops = nexthops(iface)).empty?
          `ip -4 route change default #{hops.join ' '}`
          `ip -4 route flush cache dev #{iface}`
        else
          `ip -4 route del default`
          `ip -4 route flush cache`
        end
      end
    end

    def nexthops(skip = nil)
      hops =
        if default_route.include? "\n"
          default_route.split("\n").reject! { |x| x.strip! == 'default' }
        else
          [default_route.sub(/^default/, 'nexthop')]
        end

      hops.reject! { |x| x =~ /#{skip}/ } if skip
      hops
    end

    def links
      `ip -o link ls`.split("\n").map! { |link| parse_link link }.to_h
    end

    def foreach_link_change
      File.popen('ip -o monitor link') do |io|
        while l = io.readline
          if l =~ /^Deleted /
            yield :delete, parse_link(l.gsub!(/^Deleted /, ''))
          else
            yield :change, parse_link(l)
          end
        end
      end
    end

    protected
    def nexthop(gw, iface, wgt)
      "nexthop via #{gw} dev #{iface} weight #{wgt}"
    end

    def parse_link(link)
      link.scan(/(^\d+): (\w+):/).map! {|id, iface| [iface, id.to_i]}.flatten
    end
  end
end
