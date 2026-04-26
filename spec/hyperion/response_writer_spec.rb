# frozen_string_literal: true

require 'stringio'
require 'hyperion/response_writer'

RSpec.describe Hyperion::ResponseWriter do
  subject(:writer) { described_class.new }

  let(:io) { StringIO.new }

  it 'writes a 200 response with Content-Length' do
    writer.write(io, 200, { 'content-type' => 'text/plain' }, ['hello'])

    raw = io.string
    expect(raw).to start_with("HTTP/1.1 200 OK\r\n")
    expect(raw).to include("content-type: text/plain\r\n")
    expect(raw).to include("content-length: 5\r\n")
    expect(raw).to end_with("\r\nhello")
  end

  it 'writes a 404 with the right reason phrase' do
    writer.write(io, 404, {}, ['nope'])

    expect(io.string).to start_with("HTTP/1.1 404 Not Found\r\n")
  end

  it 'always sets Connection: close in Phase 1 (no keep-alive yet)' do
    writer.write(io, 200, {}, ['x'])

    expect(io.string).to include("connection: close\r\n")
  end

  it 'concatenates multi-chunk bodies' do
    writer.write(io, 200, {}, %w[hello world])

    expect(io.string).to end_with("\r\nhelloworld")
    expect(io.string).to include("content-length: 10\r\n")
  end

  it 'iterates enumerable bodies' do
    body = Enumerator.new do |y|
      y << 'a'
      y << 'b'
    end
    writer.write(io, 200, {}, body)

    expect(io.string).to end_with("\r\nab")
  end

  it 'closes the body if it responds to close' do
    body = Class.new do
      attr_reader :closed

      def initialize(chunks)
        @chunks = chunks
        @closed = false
      end

      def each(&blk)
        @chunks.each(&blk)
      end

      def close
        @closed = true
      end
    end.new(['x'])

    writer.write(io, 200, {}, body)

    expect(body.closed).to be(true)
  end

  it 'always sets a Date header' do
    writer.write(io, 200, {}, ['x'])

    expect(io.string).to match(/^date: \w{3}, \d{2} \w{3} \d{4} \d{2}:\d{2}:\d{2} GMT\r\n/)
  end

  it 'lets app override the Date header' do
    writer.write(io, 200, { 'date' => 'Mon, 01 Jan 2026 00:00:00 GMT' }, ['x'])

    expect(io.string).to include("date: Mon, 01 Jan 2026 00:00:00 GMT\r\n")
    expect(io.string.scan(/^date:/i).count).to eq(1)
  end

  it 'overrides app-supplied content-length' do
    writer.write(io, 200, { 'content-length' => '999' }, ['hi'])

    expect(io.string).to include("content-length: 2\r\n")
    expect(io.string).not_to include("content-length: 999\r\n")
  end

  it 'rejects header values containing CRLF (response-splitting guard)' do
    expect do
      writer.write(io, 200, { 'x-evil' => "ok\r\nset-cookie: pwn=1" }, ['x'])
    end.to raise_error(ArgumentError, %r{CR/LF})
  end

  it 'emits Connection: keep-alive when keep_alive is true' do
    writer.write(io, 200, {}, ['x'], keep_alive: true)

    expect(io.string).to include("connection: keep-alive\r\n")
  end

  it 'still emits Connection: close by default (back-compat)' do
    writer.write(io, 200, {}, ['x'])

    expect(io.string).to include("connection: close\r\n")
  end

  it 'closes body even if io.write raises' do
    body = Class.new do
      attr_reader :closed

      def initialize
        @chunks = ['x']
        @closed = false
      end

      def each(&blk)
        @chunks.each(&blk)
      end

      def close
        @closed = true
      end
    end.new

    bad_io = Object.new
    def bad_io.write(_)
      raise Errno::EPIPE
    end

    expect { writer.write(bad_io, 200, {}, body) }.to raise_error(Errno::EPIPE)
    expect(body.closed).to be(true)
  end
end
