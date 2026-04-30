# frozen_string_literal: true

require 'socket'
require 'stringio'
require 'hyperion/connection'
require 'hyperion/cli'

# 2.3-B per-connection fairness cap. nginx upstream keep-alive multiplexes
# many client requests through one upstream conn; without a cap a single
# greedy upstream conn can hog the worker thread pool and starve siblings.
# The cap is opt-in (default nil = no cap, matches 2.2.0). When the cap
# fires, Hyperion writes 503 + Retry-After: 1 and keeps the conn alive
# so nginx can retry once the in-flight request drains.
RSpec.describe 'Hyperion::Connection per-conn fairness (2.3-B)' do
  let(:slow_app) do
    lambda do |env|
      sleep(0.01) # 10 ms so the cap actually has time to fire under contention
      [200, { 'content-type' => 'text/plain' }, ["seen #{env['PATH_INFO']}"]]
    end
  end

  describe 'cap is nil (default — no rejection)' do
    it 'serves keep-alive requests as 2.2.0 did' do
      a, b = ::Socket.pair(:UNIX, :STREAM)
      a.write("GET /ok HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
      a.close_write

      Hyperion::Connection.new(max_in_flight_per_conn: nil).serve(b, slow_app)

      response = a.read
      expect(response).to start_with("HTTP/1.1 200 OK\r\n")
      expect(response).not_to include('503')
    ensure
      a&.close
      b&.close
    end
  end

  describe 'cap is positive (fires when in-flight reached)' do
    it 'returns 503 + Retry-After when the simulated in-flight count is at the cap, then serves the next request normally' do
      a, b = ::Socket.pair(:UNIX, :STREAM)
      # Two requests pipelined on one conn. The first will be rejected
      # because we pre-bump @in_flight to the cap; the second arrives
      # after the simulated peer fiber drains the in-flight slot.
      a.write("GET /first HTTP/1.1\r\nHost: x\r\n\r\n")
      a.write("GET /second HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
      a.close_write

      conn = Hyperion::Connection.new(max_in_flight_per_conn: 1)
      mutex = Mutex.new
      conn.instance_variable_set(:@in_flight_mutex, mutex)

      # Pre-bump the counter to simulate a concurrent in-flight request
      # (the admit check rejects when @in_flight >= cap). After the
      # first iteration's reject, decrement back to 0 so the second
      # request admits cleanly.
      reject_observed = false
      drain_app = lambda do |env|
        # By the time the app runs, the per-conn admit succeeded —
        # @in_flight is at least 1. Just answer normally.
        [200, { 'content-type' => 'text/plain' }, ["served #{env['PATH_INFO']}"]]
      end

      # Inject the bump just before the dispatch path examines the
      # counter, then drain it once after the simulated reject.
      original_admit = conn.method(:per_conn_admit!)
      conn.define_singleton_method(:per_conn_admit!) do |socket, peer_addr|
        if reject_observed
          original_admit.call(socket, peer_addr)
        else
          reject_observed = true
          # First request: pre-bump so the real admit method observes
          # @in_flight at the cap and rejects. Then drain ourselves so
          # the second request admits.
          @in_flight = 1
          rejected = original_admit.call(socket, peer_addr)
          @in_flight = 0
          rejected
        end
      end

      conn.serve(b, drain_app)
      response = a.read

      # First request rejected with 503 + Retry-After.
      expect(response).to include('HTTP/1.1 503 Service Unavailable')
      expect(response.downcase).to include('retry-after: 1')
      expect(response.downcase).to include('per-connection overload')
      # Connection stays alive — second request gets through.
      expect(response).to include('HTTP/1.1 200 OK')
      expect(response).to include('served /second')
    ensure
      a&.close
      b&.close
    end

    it 'admits a request when in-flight is below cap' do
      a, b = ::Socket.pair(:UNIX, :STREAM)
      a.write("GET /ok HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
      a.close_write

      Hyperion::Connection.new(max_in_flight_per_conn: 4).serve(b, slow_app)

      response = a.read
      expect(response).to start_with("HTTP/1.1 200 OK\r\n")
      expect(response).not_to include('503')
    ensure
      a&.close
      b&.close
    end

    it 'releases the in-flight slot after the request completes (counter drops back to 0)' do
      a, b = ::Socket.pair(:UNIX, :STREAM)
      a.write("GET /ok HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
      a.close_write

      conn = Hyperion::Connection.new(max_in_flight_per_conn: 4)
      conn.serve(b, slow_app)

      expect(conn.instance_variable_get(:@in_flight)).to eq(0)
    ensure
      a&.close
      b&.close
    end

    it 'bumps :per_conn_overload_rejects metric on every cap-trip' do
      Hyperion.metrics.reset! if Hyperion.metrics.respond_to?(:reset!)
      a, b = ::Socket.pair(:UNIX, :STREAM)
      a.write("GET /a HTTP/1.1\r\nHost: x\r\n\r\n")
      a.write("GET /b HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
      a.close_write

      conn = Hyperion::Connection.new(max_in_flight_per_conn: 1)
      # Pre-bump to force both pipelined requests to hit the cap.
      conn.instance_variable_set(:@in_flight, 1)
      conn.instance_variable_set(:@in_flight_mutex, Mutex.new)

      conn.serve(b, slow_app)

      expect(Hyperion.metrics.snapshot[:per_conn_overload_rejects]).to be >= 1
    ensure
      a&.close
      b&.close
    end

    it 'logs a deduplicated warn (one per Connection lifetime, not per rejected request)' do
      io = StringIO.new
      logger = Hyperion::Logger.new(io: io, level: :warn, format: :text)
      runtime = Hyperion::Runtime.new(logger: logger)

      a, b = ::Socket.pair(:UNIX, :STREAM)
      a.write("GET /a HTTP/1.1\r\nHost: x\r\n\r\n")
      a.write("GET /b HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
      a.close_write

      conn = Hyperion::Connection.new(max_in_flight_per_conn: 1, runtime: runtime)
      conn.instance_variable_set(:@in_flight, 1)
      conn.instance_variable_set(:@in_flight_mutex, Mutex.new)

      conn.serve(b, slow_app)

      warn_lines = io.string.lines.count { |l| l.include?('per-connection in-flight cap hit') }
      expect(warn_lines).to eq(1)
    ensure
      a&.close
      b&.close
    end
  end

  describe 'Hyperion::Config.max_in_flight_per_conn defaults' do
    it 'defaults to nil (no cap, 2.2.0 behaviour)' do
      expect(Hyperion::Config.new.max_in_flight_per_conn).to be_nil
    end

    it 'accepts an explicit positive integer through the DSL' do
      cfg = Hyperion::Config.new
      cfg.max_in_flight_per_conn = 8
      expect(cfg.max_in_flight_per_conn).to eq(8)
    end

    it 'resolves the :auto sentinel to thread_count / 4 (floor 1) at finalize!' do
      cfg = Hyperion::Config.new
      cfg.thread_count = 16
      cfg.max_in_flight_per_conn = Hyperion::Config::MAX_IN_FLIGHT_PER_CONN_AUTO

      cfg.finalize!(workers: 1)
      expect(cfg.max_in_flight_per_conn).to eq(4)
    end

    it 'floors :auto to 1 even when thread_count is degenerate (1, 2, 3)' do
      [1, 2, 3].each do |t|
        cfg = Hyperion::Config.new
        cfg.thread_count = t
        cfg.max_in_flight_per_conn = Hyperion::Config::MAX_IN_FLIGHT_PER_CONN_AUTO

        cfg.finalize!(workers: 1)
        expect(cfg.max_in_flight_per_conn).to eq(1), "thread_count=#{t} should floor to 1"
      end
    end

    it 'leaves an explicit integer untouched after finalize!' do
      cfg = Hyperion::Config.new
      cfg.thread_count = 16
      cfg.max_in_flight_per_conn = 2

      cfg.finalize!(workers: 1)
      expect(cfg.max_in_flight_per_conn).to eq(2)
    end

    it 'leaves nil untouched after finalize! (no cap remains the default)' do
      cfg = Hyperion::Config.new
      cfg.thread_count = 16
      cfg.max_in_flight_per_conn = nil

      cfg.finalize!(workers: 1)
      expect(cfg.max_in_flight_per_conn).to be_nil
    end
  end

  describe '--max-in-flight-per-conn CLI flag' do
    def parse(argv)
      Hyperion::CLI.parse_argv!(argv.dup)
    end

    it 'parses an integer literal and lands it on Config via merge_cli!' do
      cli_opts, = parse(%w[--max-in-flight-per-conn 4])
      expect(cli_opts[:max_in_flight_per_conn]).to eq(4)

      config = Hyperion::Config.new
      config.merge_cli!(cli_opts)
      expect(config.max_in_flight_per_conn).to eq(4)
    end

    it 'parses `auto` to the MAX_IN_FLIGHT_PER_CONN_AUTO sentinel' do
      cli_opts, = parse(%w[--max-in-flight-per-conn auto])
      expect(cli_opts[:max_in_flight_per_conn]).to eq(Hyperion::Config::MAX_IN_FLIGHT_PER_CONN_AUTO)

      config = Hyperion::Config.new
      config.thread_count = 16
      config.merge_cli!(cli_opts)
      config.finalize!(workers: 1)
      expect(config.max_in_flight_per_conn).to eq(4)
    end

    it 'accepts `:auto` (with the leading colon) as an alias' do
      cli_opts, = parse(['--max-in-flight-per-conn', ':auto'])
      expect(cli_opts[:max_in_flight_per_conn]).to eq(Hyperion::Config::MAX_IN_FLIGHT_PER_CONN_AUTO)
    end

    it 'raises OptionParser::InvalidArgument on a non-integer non-`auto` value' do
      expect { parse(%w[--max-in-flight-per-conn notanumber]) }
        .to raise_error(OptionParser::InvalidArgument, /max-in-flight-per-conn/)
    end

    it 'raises on a non-positive integer (zero / negative)' do
      expect { parse(%w[--max-in-flight-per-conn 0]) }
        .to raise_error(OptionParser::InvalidArgument, /max-in-flight-per-conn/)
      expect { parse(%w[--max-in-flight-per-conn -10]) }
        .to raise_error(OptionParser::InvalidArgument)
    end
  end

  describe 'HYPERION_MAX_IN_FLIGHT_PER_CONN env-var' do
    let(:io) { StringIO.new }
    let(:logger) { Hyperion::Logger.new(io: io, level: :warn, format: :text) }
    let(:config) { Hyperion::Config.new }

    before do
      @prev_env = ENV['HYPERION_MAX_IN_FLIGHT_PER_CONN']
      @prev_logger = Hyperion::Runtime.default.logger
      Hyperion::Runtime.default.logger = logger
    end

    after do
      ENV['HYPERION_MAX_IN_FLIGHT_PER_CONN'] = @prev_env
      Hyperion::Runtime.default.logger = @prev_logger
    end

    def call!
      Hyperion::CLI.send(:apply_max_in_flight_per_conn_env_override!, config)
    end

    it 'leaves config.max_in_flight_per_conn untouched when env is unset' do
      ENV.delete('HYPERION_MAX_IN_FLIGHT_PER_CONN')
      call!
      expect(config.max_in_flight_per_conn).to be_nil
    end

    it 'maps HYPERION_MAX_IN_FLIGHT_PER_CONN=4 to the integer cap' do
      ENV['HYPERION_MAX_IN_FLIGHT_PER_CONN'] = '4'
      call!
      expect(config.max_in_flight_per_conn).to eq(4)
    end

    it 'maps HYPERION_MAX_IN_FLIGHT_PER_CONN=auto to the AUTO sentinel' do
      ENV['HYPERION_MAX_IN_FLIGHT_PER_CONN'] = 'auto'
      call!
      expect(config.max_in_flight_per_conn).to eq(Hyperion::Config::MAX_IN_FLIGHT_PER_CONN_AUTO)
    end

    it 'is a no-op when the env var is the empty string' do
      ENV['HYPERION_MAX_IN_FLIGHT_PER_CONN'] = ''
      call!
      expect(config.max_in_flight_per_conn).to be_nil
    end

    it 'warns and leaves the value untouched on an unknown setting' do
      ENV['HYPERION_MAX_IN_FLIGHT_PER_CONN'] = 'notanumber'
      config.max_in_flight_per_conn = 8
      call!
      expect(config.max_in_flight_per_conn).to eq(8)
      expect(io.string).to include('HYPERION_MAX_IN_FLIGHT_PER_CONN ignored')
    end
  end
end
