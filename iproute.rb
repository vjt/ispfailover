module IPRoute
  def default_route
    `ip -4 route ls 0.0.0.0/0`.strip!
  end
  module_function :default_route

  def local_host(interface)
    `ip -4 -o addr ls dev #{interface} scope global`.scan(/inet ((\d+\.){3}\d+)/).flatten.first
  end
  module_function :local_host

  def add_route(dest, gw, iface)
    run "ip -4 route add #{dest} via #{gw} dev #{iface}"
  end
  module_function :add_route

  def del_route(dest, gw, iface)
    run "ip -4 route del #{dest} via #{gw} dev #{iface}"
  end
  module_function :del_route

  def add_nexthop(gw, iface, wgt = 1)
    if default_route.empty?
      run "ip -4 route add default #{nexthop(gw, iface, wgt)}"
    else
      hops = nexthops(iface).push(nexthop(gw, iface, wgt))
      run "ip -4 route change default #{hops.join ' '}"
    end
  end
  module_function :add_nexthop

  def del_nexthop(gw, iface)
    hops = nexthops(iface)
    run "ip -4 route change default #{hops.join ' '}"
  end
  module_function :del_nexthop

  def nexthops(skip = nil)
    hops = if default_route.include? "\n"
             default_route.split("\n").reject! { |x| x.strip! == 'default' }
           else
             [default_route.sub(/^default/, 'nexthop')]
           end
    hops.reject! { |x| x =~ /#{skip}/ } if skip
    hops
  end
  module_function :nexthops

  protected
  def nexthop(gw, iface, wgt)
    "nexthop via #{gw} dev #{iface} weight #{wgt}"
  end
  module_function :nexthop

  def run(cmd)
    puts cmd
#    `#{cmd}`
  end
  module_function :run
end
