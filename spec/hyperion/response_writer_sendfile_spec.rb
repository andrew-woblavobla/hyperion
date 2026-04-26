# frozen_string_literal: true

require 'stringio'
require 'tempfile'
require 'hyperion'
require 'hyperion/response_writer'

RSpec.describe Hyperion::ResponseWriter, 'sendfile path' do
  subject(:writer) { described_class.new }

  let(:io) { StringIO.new }
  let(:payload) { 'lorem ipsum dolor sit amet ' * 256 } # ~6.7 KiB
  let(:tempfile) do
    Tempfile.new(%w[hyperion-sendfile .bin]).tap do |f|
      f.binmode
      f.write(payload)
      f.flush
    end
  end

  # A body that mimics Rack::Files / Rack::Files::Iterator: responds to
  # #to_path so the writer takes the zero-copy branch, and tracks #close so
  # we can assert it gets called.
  def file_body(path)
    Class.new do
      attr_reader :closed

      def initialize(path)
        @path = path
        @closed = false
      end

      def to_path
        @path
      end

      def each
        yield File.binread(@path) # never invoked when sendfile path is taken
      end

      def close
        @closed = true
      end
    end.new(path)
  end

  before do
    Hyperion.instance_variable_set(:@metrics, nil)
    Hyperion.metrics.reset!
  end

  after do
    tempfile.close!
  end

  it 'streams the file body via IO.copy_stream and bumps :sendfile_responses' do
    writer.write(io, 200, { 'content-type' => 'application/octet-stream' }, file_body(tempfile.path))

    raw = io.string
    expect(raw).to start_with("HTTP/1.1 200 OK\r\n")
    head, body = raw.split("\r\n\r\n", 2)
    expect(body).to eq(payload)
    expect(head).to include("content-length: #{payload.bytesize}")
    expect(Hyperion.metrics.snapshot[:sendfile_responses]).to eq(1)
    expect(Hyperion.metrics.snapshot[:tls_zerobuf_responses] || 0).to eq(0)
  end

  it 'writes the head before the body bytes' do
    body = file_body(tempfile.path)
    writer.write(io, 200, {}, body)

    raw = io.string
    term = raw.index("\r\n\r\n")
    expect(term).to be > 0
    head_section = raw.byteslice(0, term + 4)
    body_section = raw.byteslice(term + 4, raw.bytesize - (term + 4))
    expect(head_section).to start_with("HTTP/1.1 200 OK\r\n")
    expect(head_section).to include("content-length: #{payload.bytesize}\r\n")
    expect(body_section).to eq(payload)
  end

  it 'closes the body even when the sendfile path is taken' do
    body = file_body(tempfile.path)
    writer.write(io, 200, {}, body)

    expect(body.closed).to be(true)
  end

  it 'derives Content-Length from File.size when the app does not set one' do
    writer.write(io, 200, {}, file_body(tempfile.path))

    expect(io.string).to include("content-length: #{File.size(tempfile.path)}\r\n")
    # exactly one content-length header
    expect(io.string.scan(/^content-length:/i).count).to eq(1)
  end

  it 'matches the buffered path on status line / reason / connection header' do
    body = file_body(tempfile.path)
    writer.write(io, 200, {}, body, keep_alive: true)

    sendfile_head = io.string.split("\r\n\r\n", 2).first

    buffered_io = StringIO.new
    writer.write(buffered_io, 200, {}, [payload], keep_alive: true)
    buffered_head = buffered_io.string.split("\r\n\r\n", 2).first

    # Both heads should agree on status line, content-length, and
    # connection header. The Date header may differ if the second tick
    # rolled over between writes — strip it before comparing.
    strip_date = ->(h) { h.gsub(/^date: [^\r]+\r\n/i, '') }

    expect(strip_date.call(sendfile_head)).to eq(strip_date.call(buffered_head))
  end

  it 'closes the open File handle even if the socket write raises' do
    body = file_body(tempfile.path)
    bad_io = Object.new
    def bad_io.write(_)
      raise Errno::EPIPE
    end

    expect { writer.write(bad_io, 200, {}, body) }.to raise_error(Errno::EPIPE)
    expect(body.closed).to be(true)
  end
end
