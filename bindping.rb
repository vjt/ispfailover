# shameless rip of core's ping.rb, with a 'local' parameter added.
# also, probe is a neatier name than pingecho, which isn't dry :P.
#
require 'net/protocol'
require 'timeout'

module Ping
  def probe(host, service = 'echo', local = nil, timeout = 5)
    begin
      timeout(timeout) do
        s = TCPSocket.new(host, service, local)
        s.close
      end
    rescue Errno::ECONNREFUSED
      return true
    rescue Timeout::Error, StandardError
      return false
    end
    return true
  end
  module_function :probe
end

if $0 == __FILE__
  host = ARGV[0] || 'localhost'
  service = ARGV[1] || 'echo'
  local = ARGV[2]
  printf("%s alive? - %s\n", host, Ping.probe(host, service, local))
end
