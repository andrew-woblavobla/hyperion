# frozen_string_literal: true

require 'stringio'
require 'hyperion/tls'
require 'hyperion/cli'

# 2.3-B TLS handshake CPU throttle. Per-worker token bucket on SSL_accept
# calls. Defends direct-exposure operators against handshake storms;
# nginx-fronted topologies see this as defensive (nginx keeps long-lived
# upstream conns so handshake rate is normally near-zero). Default is
# `:unlimited` — no throttle, matches 2.2.0 behaviour.
RSpec.describe Hyperion::TLS::HandshakeRateLimiter do
  describe ':unlimited (default)' do
    it 'admits every handshake regardless of count' do
      limiter = described_class.new(:unlimited)
      results = Array.new(200) { limiter.acquire_token! }
      expect(results.count(true)).to eq(200)
      expect(results.count(false)).to eq(0)
    end

    it 'reports rate :unlimited in stats' do
      limiter = described_class.new(:unlimited)
      expect(limiter.stats[:rate]).to eq(:unlimited)
    end

    it 'accepts nil as an alias for :unlimited' do
      limiter = described_class.new(nil)
      expect(limiter.acquire_token!).to be(true)
      expect(limiter.stats[:rate]).to eq(:unlimited)
    end
  end

  describe 'positive integer rate' do
    it 'admits up to `capacity` handshakes immediately, then rejects once empty' do
      limiter = described_class.new(100)
      # Drain the bucket — capacity == rate, so 100 immediate admits.
      admitted = 0
      rejected = 0
      200.times do
        limiter.acquire_token! ? admitted += 1 : rejected += 1
      end

      # First ~100 admits, the rest rejected. The exact split depends
      # on real elapsed time during the loop (refill is monotonic), so
      # we allow a small fudge factor.
      expect(admitted).to be_between(95, 110), "expected ~100 admits, got #{admitted}"
      expect(rejected).to be_between(90, 105), "expected ~100 rejects, got #{rejected}"
    end

    it 'refills tokens over time so a steady stream at the rate eventually drains the rejected pool' do
      limiter = described_class.new(50)
      # Drain immediately.
      50.times { limiter.acquire_token! }
      # All further attempts within the same tick are rejected.
      expect(limiter.acquire_token!).to be(false)

      # Wait long enough for the bucket to refill ~half (0.5s × 50/sec
      # = 25 tokens). 25 admits should succeed afterwards.
      sleep 0.55
      admitted_after_wait = 0
      30.times { admitted_after_wait += 1 if limiter.acquire_token! }
      expect(admitted_after_wait).to be_between(20, 30),
                                     "expected ~25-30 admits after 0.55s refill, got #{admitted_after_wait}"
    end

    it 'caps tokens at capacity (no infinite accrual during long idle)' do
      limiter = described_class.new(10)
      # Bucket starts at capacity (10). Long idle would refill beyond
      # capacity if the cap weren't enforced.
      sleep 0.1
      # acquire+stats both refill internally; check we still cap at 10.
      # 11th attempt within the same tick must reject.
      admitted = 0
      11.times { admitted += 1 if limiter.acquire_token! }
      expect(admitted).to eq(10)
    end

    it 'increments rejected counter on every denied handshake' do
      limiter = described_class.new(5)
      5.times { limiter.acquire_token! } # drain
      3.times { limiter.acquire_token! } # 3 rejects

      expect(limiter.stats[:rejected]).to eq(3)
    end

    it 'is thread-safe: concurrent acquire_token! calls never over-admit' do
      limiter = described_class.new(50)
      threads = Array.new(8) do
        Thread.new do
          admitted_local = 0
          50.times { admitted_local += 1 if limiter.acquire_token! }
          admitted_local
        end
      end
      total_admitted = threads.map(&:value).sum
      # 8 threads × 50 attempts = 400 attempts. Capacity is 50.
      # Under contention some refill may occur during the run, but we
      # should never see more than capacity + (a small refill window
      # × rate) admits. 50 capacity + ~0.05 elapsed × 50 = 52.5,
      # rounded up to 60 for slack on slow CI.
      expect(total_admitted).to be_between(50, 60), "saw #{total_admitted} admits"
    end
  end

  describe 'invalid rate values' do
    it 'raises ArgumentError on a non-positive integer' do
      expect { described_class.new(0) }
        .to raise_error(ArgumentError, /must be a positive integer/)
      expect { described_class.new(-5) }
        .to raise_error(ArgumentError, /must be a positive integer/)
    end

    it 'raises ArgumentError on a non-integer non-:unlimited value' do
      expect { described_class.new(:auto) }
        .to raise_error(ArgumentError, /must be a positive integer or :unlimited/)
      expect { described_class.new('100') }
        .to raise_error(ArgumentError)
    end
  end
end

RSpec.describe 'Hyperion::Config tls.handshake_rate_limit (2.3-B)' do
  it 'defaults to :unlimited' do
    expect(Hyperion::Config.new.tls.handshake_rate_limit).to eq(:unlimited)
  end

  it 'accepts an explicit positive integer through the DSL' do
    cfg = Hyperion::Config.new
    cfg.tls.handshake_rate_limit = 200
    expect(cfg.tls.handshake_rate_limit).to eq(200)
  end
end

RSpec.describe '--tls-handshake-rate-limit CLI flag (2.3-B)' do
  def parse(argv)
    Hyperion::CLI.parse_argv!(argv.dup)
  end

  it 'parses an integer literal and lands it on Config via merge_cli!' do
    cli_opts, = parse(%w[--tls-handshake-rate-limit 250])
    expect(cli_opts[:tls_handshake_rate_limit]).to eq(250)

    config = Hyperion::Config.new
    config.merge_cli!(cli_opts)
    expect(config.tls.handshake_rate_limit).to eq(250)
  end

  it 'parses `unlimited` to the :unlimited symbol' do
    cli_opts, = parse(%w[--tls-handshake-rate-limit unlimited])
    expect(cli_opts[:tls_handshake_rate_limit]).to eq(:unlimited)

    config = Hyperion::Config.new
    config.merge_cli!(cli_opts)
    expect(config.tls.handshake_rate_limit).to eq(:unlimited)
  end

  it 'raises OptionParser::InvalidArgument on a non-integer non-`unlimited` value' do
    expect { parse(%w[--tls-handshake-rate-limit notanumber]) }
      .to raise_error(OptionParser::InvalidArgument, /tls-handshake-rate-limit/)
  end

  it 'raises on a non-positive integer' do
    expect { parse(%w[--tls-handshake-rate-limit 0]) }
      .to raise_error(OptionParser::InvalidArgument, /tls-handshake-rate-limit/)
  end
end

RSpec.describe 'HYPERION_TLS_HANDSHAKE_RATE_LIMIT env-var (2.3-B)' do
  let(:io) { StringIO.new }
  let(:logger) { Hyperion::Logger.new(io: io, level: :warn, format: :text) }
  let(:config) { Hyperion::Config.new }

  before do
    @prev_env = ENV['HYPERION_TLS_HANDSHAKE_RATE_LIMIT']
    @prev_logger = Hyperion::Runtime.default.logger
    Hyperion::Runtime.default.logger = logger
  end

  after do
    ENV['HYPERION_TLS_HANDSHAKE_RATE_LIMIT'] = @prev_env
    Hyperion::Runtime.default.logger = @prev_logger
  end

  def call!
    Hyperion::CLI.send(:apply_tls_handshake_rate_limit_env_override!, config)
  end

  it 'leaves config.tls.handshake_rate_limit untouched when env is unset' do
    ENV.delete('HYPERION_TLS_HANDSHAKE_RATE_LIMIT')
    call!
    expect(config.tls.handshake_rate_limit).to eq(:unlimited)
  end

  it 'maps HYPERION_TLS_HANDSHAKE_RATE_LIMIT=200 to the integer rate' do
    ENV['HYPERION_TLS_HANDSHAKE_RATE_LIMIT'] = '200'
    call!
    expect(config.tls.handshake_rate_limit).to eq(200)
  end

  it 'maps HYPERION_TLS_HANDSHAKE_RATE_LIMIT=unlimited to the :unlimited symbol' do
    ENV['HYPERION_TLS_HANDSHAKE_RATE_LIMIT'] = 'unlimited'
    call!
    expect(config.tls.handshake_rate_limit).to eq(:unlimited)
  end

  it 'is a no-op when the env var is the empty string' do
    ENV['HYPERION_TLS_HANDSHAKE_RATE_LIMIT'] = ''
    call!
    expect(config.tls.handshake_rate_limit).to eq(:unlimited)
  end

  it 'warns and leaves the value untouched on an unknown setting' do
    ENV['HYPERION_TLS_HANDSHAKE_RATE_LIMIT'] = 'notanumber'
    config.tls.handshake_rate_limit = 100
    call!
    expect(config.tls.handshake_rate_limit).to eq(100)
    expect(io.string).to include('HYPERION_TLS_HANDSHAKE_RATE_LIMIT ignored')
  end
end
