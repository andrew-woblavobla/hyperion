# frozen_string_literal: true

require 'hyperion/cli'

RSpec.describe 'Hyperion::CLI.maybe_enable_yjit' do
  # The CLI's helper is private; reach into it directly so we can isolate the
  # decision logic from the rest of the boot path (option parsing, rackup
  # loading, etc.). Hits the same code path operators rely on in production.
  def call(config)
    Hyperion::CLI.send(:maybe_enable_yjit, config)
  end

  let(:config) { Hyperion::Config.new }

  before do
    @env_snapshot = ENV.to_h.slice('RAILS_ENV', 'RACK_ENV', 'HYPERION_ENV')
    %w[RAILS_ENV RACK_ENV HYPERION_ENV].each { |k| ENV.delete(k) }
  end

  after do
    %w[RAILS_ENV RACK_ENV HYPERION_ENV].each { |k| ENV.delete(k) }
    @env_snapshot.each { |k, v| ENV[k] = v }
  end

  context 'when this Ruby ships YJIT' do
    before do
      skip 'YJIT not available in this Ruby' unless defined?(::RubyVM::YJIT)

      # YJIT.enable is a one-shot toggle in real Ruby — stub it so the test
      # doesn't actually flip the JIT state for the rest of the suite.
      allow(::RubyVM::YJIT).to receive(:enabled?).and_return(false)
      allow(::RubyVM::YJIT).to receive(:enable)
    end

    it 'auto-enables YJIT when RAILS_ENV=production and config.yjit is nil' do
      ENV['RAILS_ENV'] = 'production'
      call(config)
      expect(::RubyVM::YJIT).to have_received(:enable)
    end

    it 'auto-enables YJIT when RACK_ENV=staging' do
      ENV['RACK_ENV'] = 'staging'
      call(config)
      expect(::RubyVM::YJIT).to have_received(:enable)
    end

    it 'does NOT enable YJIT in development by default' do
      ENV['RAILS_ENV'] = 'development'
      call(config)
      expect(::RubyVM::YJIT).not_to have_received(:enable)
    end

    it 'does NOT enable YJIT when no env vars are set and config.yjit is nil' do
      call(config)
      expect(::RubyVM::YJIT).not_to have_received(:enable)
    end

    it 'forces YJIT on when config.yjit = true even in development' do
      ENV['RAILS_ENV'] = 'development'
      config.yjit = true
      call(config)
      expect(::RubyVM::YJIT).to have_received(:enable)
    end

    it 'forces YJIT off when config.yjit = false even in production' do
      ENV['RAILS_ENV'] = 'production'
      config.yjit = false
      call(config)
      expect(::RubyVM::YJIT).not_to have_received(:enable)
    end

    it 'is a no-op when YJIT is already enabled (idempotent)' do
      allow(::RubyVM::YJIT).to receive(:enabled?).and_return(true)
      ENV['RAILS_ENV'] = 'production'
      call(config)
      expect(::RubyVM::YJIT).not_to have_received(:enable)
    end
  end
end
