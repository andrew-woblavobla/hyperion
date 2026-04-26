# frozen_string_literal: true

RSpec.describe Hyperion::ThreadPool do
  let(:request) do
    Hyperion::Request.new(
      method: 'GET', path: '/', query_string: '',
      http_version: 'HTTP/1.1', headers: { 'host' => 'x' }, body: ''
    )
  end

  it 'runs jobs on worker threads, not the caller thread' do
    pool = described_class.new(size: 2)
    caller_thread = Thread.current
    handler_thread = nil
    app = lambda do |_env|
      handler_thread = Thread.current
      [200, {}, []]
    end

    pool.call(app, request)
    expect(handler_thread).not_to eq(caller_thread)
  ensure
    pool&.shutdown
  end

  it 'serves multiple jobs concurrently' do
    pool = described_class.new(size: 4)
    slow_app = lambda do |_env|
      sleep 0.1
      [200, {}, []]
    end

    started = Time.now
    threads = Array.new(4) { Thread.new { pool.call(slow_app, request) } }
    threads.each(&:join)
    elapsed = Time.now - started

    # 4 jobs x 0.1s on 4 threads should complete in ~0.1s, not 0.4s.
    expect(elapsed).to be < 0.25
  ensure
    pool&.shutdown
  end

  describe '#submit_connection' do
    it 'runs Connection#serve on a worker thread' do
      pool = described_class.new(size: 2)

      a, b = ::Socket.pair(:UNIX, :STREAM)
      a.write("GET /sc HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
      a.close_write

      handler_thread = nil
      done = Queue.new
      app = lambda do |env|
        handler_thread = Thread.current
        done << :ok
        [200, { 'content-type' => 'text/plain' }, ["served #{env['PATH_INFO']}"]]
      end

      pool.submit_connection(b, app)
      done.pop

      response = a.read
      expect(response).to include('served /sc')
      expect(handler_thread).not_to eq(Thread.current)
    ensure
      a&.close
      pool&.shutdown
    end
  end
end
