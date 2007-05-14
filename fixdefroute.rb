#!/usr/bin/ruby
# vim: ts=2 expandtab sw=2

#IFACE   physical name of the interface being processed
#LOGICAL logical name of the interface being processed
#ADDRFAM address family of the interface
#METHOD  method of the interface (e.g., static)
#MODE    start if run from ifup, stop if run from ifdown
#PHASE   as per MODE, but with finer granularity, distinguishing the pre-up, post-up, pre-down and post-down phases.

require 'yaml'
Dir.chdir(File.dirname(__FILE__))

class MultipleDefaultRouteUpdater
  def initialize(interface)
    @iface = interface
    conf = YAML.load File.read('fixdefroute.yml')
    conf[interface].each do |key, val|
      instance_variable_set "@#{key}", val
    end
    puts "Initializing #@name..."
  end

  def start
    if default_route.empty?
      add nexthop
    else
      change other_hops.push(nexthop)
    end
	end

  def stop
    change other_hops unless default_route.empty?
  end
  
  protected
  def method_missing(meth, *args, &block)
    super(meth, *args, &block) unless [:add, :change].include? meth

    hops = [args.first].flatten
    unless hops.empty?
      command = "ip route #{meth} default #{hops.join ' '}"
      puts command
      Kernel.exec command
    end
  end

  def other_hops
    if default_route.include? "\n"
      default_route.split("\n").reject! do |x|
        x.strip! == 'default' or x =~ /#@iface/
      end
    else
      [default_route.sub(/^default/, 'nexthop')]
    end
  end

  def nexthop
    "nexthop via #@gateway dev #@iface weight #@weight"
  end

  def default_route
    @default_route ||= `ip route ls 0.0.0.0/0`.strip
  end
end

if __FILE__ == $0
  engine = MultipleDefaultRouteUpdater.new(ENV['IFACE'])
  engine.send ENV['MODE'].downcase.to_sym
end
