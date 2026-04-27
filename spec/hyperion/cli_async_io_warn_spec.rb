# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'hyperion/cli'

# warn_orphan_async_io: advisory log line at boot when --async-io is set but
# no fiber-cooperative library is loaded. The operator's setting is still
# honoured; the warn just nudges them at the bench cost they're paying.
RSpec.describe Hyperion::CLI, '.warn_orphan_async_io' do
  let(:io) { StringIO.new }
  let(:logger) { Hyperion::Logger.new(io: io, level: :info, format: :text) }

  before do
    @prev_logger = Hyperion.logger
    Hyperion.logger = logger
  end

  after do
    Hyperion.logger = @prev_logger
  end

  def with_config(async_io:)
    config = Hyperion::Config.new
    config.async_io = async_io
    config
  end

  it 'fires a warn when async_io: true and no fiber-cooperative library is loaded' do
    described_class.send(:warn_orphan_async_io, with_config(async_io: true))
    expect(io.string).to include('async_io enabled but no fiber-cooperative I/O library detected')
  end

  it 'is silent when async_io is false' do
    described_class.send(:warn_orphan_async_io, with_config(async_io: false))
    expect(io.string).to be_empty
  end

  it 'is silent when async_io is nil (the 1.4.0+ default — auto inline-on-TLS)' do
    described_class.send(:warn_orphan_async_io, with_config(async_io: nil))
    expect(io.string).to be_empty
  end

  it 'is silent when async_io: true and Hyperion::AsyncPg is loaded' do
    stub_const('Hyperion::AsyncPg', Module.new)
    described_class.send(:warn_orphan_async_io, with_config(async_io: true))
    expect(io.string).to be_empty
  end
end
