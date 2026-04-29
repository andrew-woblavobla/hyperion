# frozen_string_literal: true

require 'async'
require 'protocol/http2'

# Hotfix C2: empty-body responses (RFC 7230 §3.3.3 — 204, 304, and any
# response to a HEAD request) MUST NOT carry a DATA frame on HTTP/2. The
# pre-fix dispatch path took the `WriterContext#encode_mutex` twice —
# once around `send_headers`, once around an empty `send_data` flagged
# END_STREAM — and pumped two chunks through the connection-wide send
# queue, waking the dedicated writer fiber twice for a response that
# carries no body.
#
# After the fix:
#   * `body_suppressed?` returns true for 204/304 + HEAD,
#   * `dispatch_stream` folds END_STREAM onto the HEADERS frame,
#   * exactly one mutex acquisition + one queue handoff per response.
#
# These specs drive the dispatch path directly with a fake stream that
# captures `send_headers` / `send_data` calls, plus a wrapper that counts
# `encode_mutex.synchronize` invocations on the real WriterContext.
RSpec.describe Hyperion::Http2Handler, 'empty-body short-circuit' do
  # Counting mutex wrapper. Quacks like a Mutex (only the methods
  # WriterContext consumers actually call: `synchronize`). Records every
  # acquisition for assertions.
  class CountingMutex
    attr_reader :acquisitions

    def initialize
      @inner = ::Mutex.new
      @acquisitions = 0
    end

    def synchronize(&block)
      @acquisitions += 1
      @inner.synchronize(&block)
    end
  end

  # WriterContext drop-in that swaps in a CountingMutex for `encode_mutex`.
  # All other behaviour delegates to the real class.
  class CountingWriterContext < Hyperion::Http2Handler::WriterContext
    def initialize(*)
      super
      @counting_mutex = CountingMutex.new
    end

    def encode_mutex
      @counting_mutex
    end

    def mutex_acquisitions
      @counting_mutex.acquisitions
    end
  end

  # Minimal stream stand-in. dispatch_stream touches:
  #   - request_headers (for partition_pseudo)
  #   - protocol_error?
  #   - id, closed?
  #   - send_headers(headers, flags = 0)
  #   - send_data(data, flags = 0)
  #   - available_frame_size, wait_for_window  (only on body path)
  class FakeStream
    attr_reader :send_headers_calls, :send_data_calls, :request_headers, :request_body

    def initialize(request_headers:, request_body: '')
      @request_headers = request_headers
      @request_body = request_body
      @send_headers_calls = []
      @send_data_calls = []
      @available = 1 << 20
    end

    def protocol_error?
      false
    end

    def id
      1
    end

    def closed?
      false
    end

    # Match protocol-http2's Stream#send_headers signature: (headers, flags = 0)
    def send_headers(headers, flags = 0)
      @send_headers_calls << [headers, flags]
    end

    def send_data(data, flags = 0)
      @send_data_calls << [data.dup, flags]
    end

    def available_frame_size
      @available
    end

    def wait_for_window
      # Body path never reaches here in the short-circuit cases.
      raise 'unexpected wait_for_window'
    end

    # Headers were sent with END_STREAM iff exactly one send_headers call
    # carried the END_STREAM flag and no DATA frames followed.
    def end_stream_on_headers?
      @send_headers_calls.size == 1 &&
        (@send_headers_calls[0][1] & ::Protocol::HTTP2::END_STREAM).positive?
    end
  end

  def build_request_headers(method:, path: '/', authority: 'example.com')
    [
      [':method', method],
      [':scheme', 'https'],
      [':path', path],
      [':authority', authority],
      ['accept', '*/*']
    ]
  end

  describe '#body_suppressed?' do
    let(:handler) { described_class.new(app: ->(_env) { [200, {}, []] }) }

    it 'returns true for 204 No Content regardless of method' do
      expect(handler.send(:body_suppressed?, 'GET', 204)).to be(true)
      expect(handler.send(:body_suppressed?, 'POST', 204)).to be(true)
    end

    it 'returns true for 304 Not Modified regardless of method' do
      expect(handler.send(:body_suppressed?, 'GET', 304)).to be(true)
    end

    it 'returns true for HEAD regardless of status' do
      expect(handler.send(:body_suppressed?, 'HEAD', 200)).to be(true)
      expect(handler.send(:body_suppressed?, 'HEAD', 404)).to be(true)
    end

    it 'returns false for 200 GET (the normal path)' do
      expect(handler.send(:body_suppressed?, 'GET', 200)).to be(false)
    end

    it 'returns false for 404 GET (error responses still carry an error body)' do
      expect(handler.send(:body_suppressed?, 'GET', 404)).to be(false)
    end
  end

  describe '#dispatch_stream short-circuit (Async-driven)' do
    # dispatch_stream is private but exercised through #send so the spec
    # asserts the actual production code path.
    def dispatch(handler, stream, ctx)
      Async do
        handler.send(:dispatch_stream, stream, ctx, '127.0.0.1')
      end.wait
    end

    let(:ctx) { CountingWriterContext.new }

    it '204 No Content takes ONE mutex acquisition and emits no DATA frame' do
      app = ->(_env) { [204, { 'x-custom' => 'yes' }, []] }
      handler = described_class.new(app: app)
      stream = FakeStream.new(request_headers: build_request_headers(method: 'GET'))

      dispatch(handler, stream, ctx)

      expect(ctx.mutex_acquisitions).to eq(1)
      expect(stream.send_data_calls).to be_empty
      expect(stream.end_stream_on_headers?).to be(true)
    end

    it '304 Not Modified takes ONE mutex acquisition and emits no DATA frame' do
      app = ->(_env) { [304, { 'etag' => '"abc"' }, []] }
      handler = described_class.new(app: app)
      stream = FakeStream.new(request_headers: build_request_headers(method: 'GET'))

      dispatch(handler, stream, ctx)

      expect(ctx.mutex_acquisitions).to eq(1)
      expect(stream.send_data_calls).to be_empty
      expect(stream.end_stream_on_headers?).to be(true)
    end

    it 'HEAD with empty body short-circuits to ONE mutex + END_STREAM on HEADERS' do
      app = ->(_env) { [200, { 'content-type' => 'text/plain' }, []] }
      handler = described_class.new(app: app)
      stream = FakeStream.new(request_headers: build_request_headers(method: 'HEAD'))

      dispatch(handler, stream, ctx)

      expect(ctx.mutex_acquisitions).to eq(1)
      expect(stream.send_data_calls).to be_empty
      expect(stream.end_stream_on_headers?).to be(true)
    end

    it 'HEAD with non-empty body still short-circuits — body bytes are discarded per RFC' do
      # Per RFC 7230 §4.3.2, a HEAD response MUST NOT include a body even
      # if the application returned one. The C2 short-circuit fires
      # regardless: the body the app built is dropped on the floor.
      app = ->(_env) { [200, { 'content-type' => 'text/html' }, ['<html>...</html>']] }
      handler = described_class.new(app: app)
      stream = FakeStream.new(request_headers: build_request_headers(method: 'HEAD'))

      dispatch(handler, stream, ctx)

      expect(ctx.mutex_acquisitions).to eq(1)
      expect(stream.send_data_calls).to be_empty
      expect(stream.end_stream_on_headers?).to be(true)
    end

    it '200 GET with a body takes the full path: TWO mutex acquisitions + DATA frame' do
      app = ->(_env) { [200, { 'content-type' => 'text/plain' }, ['hello']] }
      handler = described_class.new(app: app)
      stream = FakeStream.new(request_headers: build_request_headers(method: 'GET'))

      dispatch(handler, stream, ctx)

      # send_headers under one synchronize, send_data under another.
      expect(ctx.mutex_acquisitions).to eq(2)
      expect(stream.send_data_calls.size).to eq(1)
      data, flags = stream.send_data_calls[0]
      expect(data).to eq('hello')
      expect(flags & ::Protocol::HTTP2::END_STREAM).to be_positive
      # HEADERS frame must NOT carry END_STREAM on the body path.
      headers_flags = stream.send_headers_calls[0][1]
      expect(headers_flags & ::Protocol::HTTP2::END_STREAM).to eq(0)
    end

    it '200 GET with an EMPTY body takes the normal path (no short-circuit on empty body alone)' do
      # The brief is explicit: short-circuit only fires for 204/304 + HEAD.
      # An empty 200 body still goes through send_body's empty branch
      # (which emits a DATA frame with END_STREAM and zero bytes).
      app = ->(_env) { [200, { 'content-type' => 'text/plain' }, []] }
      handler = described_class.new(app: app)
      stream = FakeStream.new(request_headers: build_request_headers(method: 'GET'))

      dispatch(handler, stream, ctx)

      expect(ctx.mutex_acquisitions).to eq(2)
      expect(stream.send_data_calls.size).to eq(1)
      data, flags = stream.send_data_calls[0]
      expect(data).to eq('')
      expect(flags & ::Protocol::HTTP2::END_STREAM).to be_positive
    end
  end
end
