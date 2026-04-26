# frozen_string_literal: true

require 'stringio'
require 'json'

RSpec.describe Hyperion::Logger do
  subject(:logger) { described_class.new(io: io, level: :info, format: :text) }

  let(:io) { StringIO.new }

  it 'emits structured key=value lines' do
    logger.info({ message: 'started', port: 9292, host: '127.0.0.1' })
    line = io.string
    expect(line).to include('INFO')
    expect(line).to include('[hyperion]')
    expect(line).to include('message=started')
    expect(line).to include('port=9292')
  end

  it 'respects level (skips below threshold)' do
    logger.debug({ message: 'noisy' })
    expect(io.string).to be_empty
    logger.warn({ message: 'pay attention' })
    expect(io.string).to include('WARN')
  end

  it 'emits json when format is :json' do
    json_logger = described_class.new(io: io, level: :info, format: :json)
    json_logger.warn({ message: 'foo', code: 42 })

    parsed = JSON.parse(io.string.strip)
    expect(parsed['level']).to eq('warn')
    expect(parsed['message']).to eq('foo')
    expect(parsed['code']).to eq(42)
    expect(parsed['source']).to eq('hyperion')
  end

  it 'accepts a block to defer payload construction' do
    logger.debug { raise 'should not be called when level is info' }
    expect { logger.debug { raise 'should not be called when level is info' } }.not_to raise_error
  end

  it 'falls back to message when given a string' do
    logger.info('plain text')
    # value is quoted because it contains whitespace
    expect(io.string).to include('message="plain text"')
  end

  it 'reads level from ENV when not set explicitly' do
    ENV['HYPERION_LOG_LEVEL'] = 'error'
    env_logger = described_class.new(io: io)
    expect(env_logger.level).to eq(:error)
    env_logger.warn({ message: 'should not appear' })
    expect(io.string).to be_empty
  ensure
    ENV.delete('HYPERION_LOG_LEVEL')
  end

  describe 'stdout/stderr split (12-factor)' do
    subject(:split_logger) { described_class.new(out: out, err: err, level: :debug, format: :text) }

    let(:out) { StringIO.new }
    let(:err) { StringIO.new }

    it 'routes info to stdout, warn/error/fatal to stderr' do
      split_logger.debug({ message: 'd' })
      split_logger.info({ message: 'i' })
      split_logger.warn({ message: 'w' })
      split_logger.error({ message: 'e' })
      split_logger.fatal({ message: 'f' })

      expect(out.string).to include('message=d')
      expect(out.string).to include('message=i')
      expect(out.string).not_to include('message=w')
      expect(out.string).not_to include('message=e')
      expect(out.string).not_to include('message=f')

      expect(err.string).to include('message=w')
      expect(err.string).to include('message=e')
      expect(err.string).to include('message=f')
      expect(err.string).not_to include('message=i')
    end
  end

  describe 'format auto-detection' do
    it 'defaults to json when RAILS_ENV is production' do
      ENV['RAILS_ENV'] = 'production'
      auto_logger = described_class.new(io: io)
      expect(auto_logger.format).to eq(:json)
    ensure
      ENV.delete('RAILS_ENV')
    end

    it 'defaults to json when RACK_ENV is staging' do
      ENV['RACK_ENV'] = 'staging'
      auto_logger = described_class.new(io: io)
      expect(auto_logger.format).to eq(:json)
    ensure
      ENV.delete('RACK_ENV')
    end

    it 'defaults to text when stderr is a TTY (development run)' do
      tty_io = StringIO.new
      def tty_io.tty? = true

      auto_logger = described_class.new(io: tty_io)
      expect(auto_logger.format).to eq(:text)
    end

    it 'defaults to json when output is piped (non-TTY) and no env hint' do
      auto_logger = described_class.new(io: io) # StringIO is not a TTY
      expect(auto_logger.format).to eq(:json)
    end

    it 'colorizes the level label when emitting text to a TTY' do
      tty_io = StringIO.new
      def tty_io.tty? = true

      tty_logger = described_class.new(io: tty_io, level: :info, format: :text)
      tty_logger.warn({ message: 'caution' })

      expect(tty_io.string).to include("\e[33m") # yellow for warn
      expect(tty_io.string).to include("\e[0m")  # reset
    end

    it 'does not colorize when format is text but io is not a TTY' do
      logger.warn({ message: 'no colors here' })
      expect(io.string).not_to include("\e[")
    end

    it 'honors explicit json format even on a TTY' do
      tty_io = StringIO.new
      def tty_io.tty? = true

      json_logger = described_class.new(io: tty_io, format: :json)
      expect(json_logger.format).to eq(:json)
    end

    it 'treats format: :auto the same as no value' do
      ENV['RAILS_ENV'] = 'production'
      auto_logger = described_class.new(io: io, format: :auto)
      expect(auto_logger.format).to eq(:json)
    ensure
      ENV.delete('RAILS_ENV')
    end
  end
end
