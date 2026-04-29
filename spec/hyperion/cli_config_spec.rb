# frozen_string_literal: true

require 'tempfile'
require 'net/http'
require 'socket'
require 'timeout'

RSpec.describe 'Hyperion::CLI with --config' do
  it 'loads bind/port/log_format from the config file' do
    rackup = Tempfile.new(['hello', '.ru'])
    rackup.write("run ->(_e) { [200, {'content-type' => 'text/plain'}, ['cfg']] }\n")
    rackup.close

    config = Tempfile.new(['hyperion', '.rb'])
    port = pick_free_port
    config.write(<<~RUBY)
      bind '127.0.0.1'
      port #{port}
      logging do
        format :json
        requests false
      end
    RUBY
    config.close

    bin = File.expand_path('../../bin/hyperion', __dir__)
    pid = Process.spawn(bin, '-C', config.path, rackup.path,
                        out: '/dev/null', err: '/dev/null')

    wait_for_port(port, 5)
    response = Net::HTTP.get(URI("http://127.0.0.1:#{port}/x"))
    expect(response).to eq('cfg')
  ensure
    if pid
      begin
        Process.kill('TERM', pid)
      rescue StandardError
        nil
      end
      begin
        Timeout.timeout(5) { Process.waitpid(pid) }
      rescue StandardError
        begin
          Process.kill('KILL', pid)
        rescue StandardError
          nil
        end
        begin
          Process.waitpid(pid)
        rescue StandardError
          nil
        end
      end
    end
    rackup&.unlink
    config&.unlink
  end

  def pick_free_port
    s = TCPServer.new('127.0.0.1', 0)
    port = s.addr[1]
    s.close
    port
  end

  def wait_for_port(port, timeout)
    deadline = Time.now + timeout
    loop do
      s = TCPSocket.new('127.0.0.1', port)
      s.close
      return
    rescue Errno::ECONNREFUSED
      raise "port #{port} not bound" if Time.now > deadline

      sleep 0.05
    end
  end
end
