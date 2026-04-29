# frozen_string_literal: true

require 'spec_helper'
require 'rack/lint'

RSpec.describe Hyperion::LintWrapperPool do
  let(:app) { ->(_env) { [200, { 'content-type' => 'text/plain' }, ['ok']] } }
  let(:env) do
    {
      'REQUEST_METHOD' => 'GET',
      'PATH_INFO' => '/',
      'QUERY_STRING' => '',
      'SERVER_NAME' => 'localhost',
      'SERVER_PORT' => '80',
      'SERVER_PROTOCOL' => 'HTTP/1.1',
      'rack.url_scheme' => 'http',
      'rack.input' => StringIO.new(String.new('', encoding: Encoding::ASCII_8BIT)),
      'rack.errors' => $stderr
    }
  end

  before do
    described_class.reset!
    @prev_rack_env = ENV['RACK_ENV']
    ENV['RACK_ENV'] = 'development'
  end

  after do
    ENV['RACK_ENV'] = @prev_rack_env
    described_class.reset!
  end

  describe '.acquire / .release' do
    it 'reuses the same Wrapper across 3 requests' do
      w1 = described_class.acquire(app, env)
      described_class.release(w1)

      w2 = described_class.acquire(app, env)
      expect(w2).to be(w1)

      described_class.release(w2)
      w3 = described_class.acquire(app, env)
      expect(w3).to be(w1)

      described_class.release(w3)
    end

    it 'rebinds @app and @env on each acquire (clean state for the new request)' do
      first_app  = ->(_e) { [200, {}, []] }
      first_env  = env.merge('PATH_INFO' => '/first')
      second_app = ->(_e) { [201, {}, []] }
      second_env = env.merge('PATH_INFO' => '/second')

      w = described_class.acquire(first_app, first_env)
      expect(w.instance_variable_get(:@app)).to be(first_app)
      expect(w.instance_variable_get(:@env)).to be(first_env)
      described_class.release(w)

      w2 = described_class.acquire(second_app, second_env)
      expect(w2).to be(w)
      expect(w2.instance_variable_get(:@app)).to be(second_app)
      expect(w2.instance_variable_get(:@env)).to be(second_env)
      expect(w2.instance_variable_get(:@response)).to be_nil
      expect(w2.instance_variable_get(:@status)).to be_nil
      expect(w2.instance_variable_get(:@closed)).to be(false)
      expect(w2.instance_variable_get(:@size)).to eq(0)
      described_class.release(w2)
    end

    it 'caps the pool at MAX_POOL_SIZE — extra releases drop on the floor' do
      cap = Hyperion::LintWrapperPool::MAX_POOL_SIZE
      wrappers = Array.new(cap + 5) { described_class.acquire(app, env) }
      wrappers.each { |w| described_class.release(w) }

      expect(described_class.pool_size).to eq(cap)
    end
  end

  describe 'production short-circuit' do
    it 'allocates fresh in RACK_ENV=production and #release is a no-op' do
      ENV['RACK_ENV'] = 'production'
      described_class.reset!

      w1 = described_class.acquire(app, env)
      expect(w1).to be_a(::Rack::Lint::Wrapper)
      described_class.release(w1)
      expect(described_class.pool_size).to eq(0)

      w2 = described_class.acquire(app, env)
      expect(w2).not_to be(w1)
      described_class.release(w2)
      expect(described_class.pool_size).to eq(0)
    end

    it 'honours RACK_LINT_DISABLE=1 like production (no pool reuse)' do
      ENV['RACK_LINT_DISABLE'] = '1'
      begin
        described_class.reset!
        w1 = described_class.acquire(app, env)
        described_class.release(w1)
        w2 = described_class.acquire(app, env)
        expect(w2).not_to be(w1)
      ensure
        ENV.delete('RACK_LINT_DISABLE')
      end
    end
  end

  describe 'lint semantics preserved on a reused wrapper' do
    it 'still validates the response across reuse' do
      w = described_class.acquire(app, env)
      result = w.response
      expect(result[0]).to eq(200)
      described_class.release(w)

      bad_app = ->(_e) { [200, {}, [Object.new]] } # body items must respond to to_str
      w2 = described_class.acquire(bad_app, env)
      expect(w2).to be(w)
      _status, _headers, body = w2.response
      expect { body.each { |_| } }.to raise_error(Rack::Lint::LintError)
      described_class.release(w2)
    end
  end
end
