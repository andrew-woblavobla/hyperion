# frozen_string_literal: true

require 'net/http'
require 'socket'
require 'timeout'

RSpec.describe Hyperion::Master do
  describe '.detect_worker_model' do
    after { ENV.delete('HYPERION_WORKER_MODEL') }

    it 'returns :reuseport on Linux' do
      stub_const('RbConfig::CONFIG', RbConfig::CONFIG.merge('host_os' => 'linux-gnu'))
      expect(described_class.detect_worker_model).to eq(:reuseport)
    end

    it 'returns :share on Darwin' do
      stub_const('RbConfig::CONFIG', RbConfig::CONFIG.merge('host_os' => 'darwin23.4.0'))
      expect(described_class.detect_worker_model).to eq(:share)
    end

    it 'returns :share on FreeBSD/openbsd' do
      stub_const('RbConfig::CONFIG', RbConfig::CONFIG.merge('host_os' => 'freebsd14.0'))
      expect(described_class.detect_worker_model).to eq(:share)
    end

    it 'honors HYPERION_WORKER_MODEL override' do
      ENV['HYPERION_WORKER_MODEL'] = 'reuseport'
      stub_const('RbConfig::CONFIG', RbConfig::CONFIG.merge('host_os' => 'darwin23'))
      expect(described_class.detect_worker_model).to eq(:reuseport)
    end

    it 'ignores invalid HYPERION_WORKER_MODEL values' do
      ENV['HYPERION_WORKER_MODEL'] = 'nonsense'
      stub_const('RbConfig::CONFIG', RbConfig::CONFIG.merge('host_os' => 'linux-gnu'))
      expect(described_class.detect_worker_model).to eq(:reuseport)
    end
  end

  it 'forks workers, serves requests, and shuts down cleanly on SIGTERM' do
    bin = File.expand_path('../../bin/hyperion', __dir__)
    rackup = Tempfile.new(['hello', '.ru'])
    rackup.write(<<~RU)
      run ->(_env) { [200, { 'content-type' => 'text/plain' }, ['cluster']] }
    RU
    rackup.close

    port = pick_free_port
    pid  = Process.spawn(bin, '-w', '2', '-p', port.to_s, rackup.path,
                         out: '/dev/null', err: '/dev/null')

    wait_for_port(port, 5)

    response = Net::HTTP.get(URI("http://127.0.0.1:#{port}/cluster"))
    expect(response).to eq('cluster')

    Process.kill('TERM', pid)
    Timeout.timeout(10) { Process.waitpid(pid) }
    expect($?.success? || $?.signaled?).to be(true)
  ensure
    rackup&.unlink
    if pid
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
      raise "port #{port} not bound within #{timeout}s" if Time.now > deadline

      sleep 0.05
    end
  end
end
