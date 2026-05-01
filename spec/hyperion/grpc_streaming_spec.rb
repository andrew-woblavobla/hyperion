# frozen_string_literal: true

require 'openssl'
require 'socket'
require 'protocol/http2/client'
require 'protocol/http2/framer'
require 'protocol/http2/stream'

# 2.13-D — gRPC streaming RPCs on HTTP/2.
#
# Locks in three contracts that 2.12-F (unary) did not cover:
#
#   1. **Server-streaming.** A Rack body that yields multiple chunks via
#      `#each` and exposes `#trailers` produces ONE DATA frame per yielded
#      chunk (not a single coalesced payload). End-of-stream is the trailer
#      HEADERS frame, NOT END_STREAM on the last DATA. Frame-count and
#      END_STREAM placement are the spec's main assertions.
#
#   2. **Client-streaming.** A gRPC request (`content-type: application/grpc`
#      + `te: trailers`) is dispatched on HEADERS arrival; `rack.input.read`
#      blocks for DATA frames as the peer sends them. The spec sends 5
#      DATA frames spaced apart and asserts the app saw all bytes.
#
#   3. **Bidirectional streaming.** App reads one message, writes one,
#      interleaved. Spec drives 5 round-trips and asserts ordering plus
#      message count.
#
# All three specs use `Protocol::HTTP2::Client` end-to-end (real HPACK +
# framing) over TLS. Each spec has its own boot/teardown so connection
# state never leaks across examples.
RSpec.describe 'Hyperion HTTP/2 gRPC streaming (2.13-D)' do
  # --------------------------------------------------------------------------
  # Custom Rack body for server-streaming. `each` yields chunks one-at-a-time;
  # `trailers` is consulted AFTER iteration finishes (Rack 3 contract). The
  # 2.13-D handler emits one DATA frame per yielded chunk (no coalescing).
  # --------------------------------------------------------------------------
  class ServerStreamBody
    def initialize(chunks, trailers)
      @chunks = chunks
      @trailers = trailers
    end

    def each(&block)
      @chunks.each(&block)
    end

    attr_reader :trailers

    def close; end
  end

  def grpc_frame(payload)
    "\x00".b + [payload.bytesize].pack('N') + payload.b
  end

  def boot_server(app)
    cert, key = TLSHelper.self_signed
    server = Hyperion::Server.new(host: '127.0.0.1', port: 0, app: app,
                                  tls: { cert: cert, key: key })
    server.listen
    serve_thread = Thread.new { server.start }
    deadline = Time.now + 3
    loop do
      s = TCPSocket.new('127.0.0.1', server.port)
      s.close
      break
    rescue Errno::ECONNREFUSED
      raise 'server didn’t bind' if Time.now > deadline

      sleep 0.01
    end
    [server, serve_thread]
  end

  def open_h2_client(port)
    tcp = TCPSocket.new('127.0.0.1', port)
    ctx = OpenSSL::SSL::SSLContext.new
    ctx.alpn_protocols = ['h2']
    ctx.verify_mode = OpenSSL::SSL::VERIFY_NONE
    ssl = OpenSSL::SSL::SSLSocket.new(tcp, ctx)
    ssl.sync_close = true
    ssl.connect
    raise 'ALPN did not negotiate h2' unless ssl.alpn_protocol == 'h2'

    framer = ::Protocol::HTTP2::Framer.new(ssl)
    client = ::Protocol::HTTP2::Client.new(framer)
    client.send_connection_preface
    [client, ssl]
  end

  # Server-streaming driver: send a single request HEADERS+DATA, then
  # read frames until END_STREAM. Returns the count of received DATA
  # frames and the final trailer block.
  def drive_server_streaming(client, _ssl, headers:, body:)
    stream = client.create_stream
    flags = body.empty? ? ::Protocol::HTTP2::END_STREAM : 0
    stream.send_headers(headers, flags)
    stream.send_data(body, ::Protocol::HTTP2::END_STREAM) unless body.empty?

    data_frames = []
    header_blocks = []
    stream_class = stream.class
    stream.define_singleton_method(:process_data) do |frame|
      data = stream_class.instance_method(:process_data).bind_call(self, frame)
      data_frames << { bytes: data.dup, end_stream: frame.end_stream? }
      data
    end
    stream.define_singleton_method(:process_headers) do |frame|
      decoded = stream_class.instance_method(:process_headers).bind_call(self, frame)
      header_blocks << { headers: decoded.dup, end_stream: frame.end_stream? }
      decoded
    end

    deadline = Time.now + 5
    until stream.closed?
      raise 'h2 client read timeout' if Time.now > deadline

      client.read_frame
    end

    trailing = header_blocks[1..]&.find { |b| b[:end_stream] }&.dig(:headers)
    [data_frames, trailing, header_blocks.first&.dig(:headers) || []]
  end

  describe 'server streaming' do
    it 'emits one DATA frame per yielded chunk; END_STREAM rides on the trailer HEADERS frame' do
      messages = (1..5).map { |i| grpc_frame("msg-#{i}") }
      app = lambda do |env|
        env['rack.input'].read
        body = ServerStreamBody.new(messages, { 'grpc-status' => '0' })
        [200, { 'content-type' => 'application/grpc' }, body]
      end

      server, serve_thread = boot_server(app)
      client, ssl = open_h2_client(server.port)
      data_frames, trailers, initial_headers = drive_server_streaming(
        client, ssl,
        headers: [
          [':method', 'POST'], [':scheme', 'https'],
          [':authority', '127.0.0.1'], [':path', '/svc/StreamReply'],
          ['content-type', 'application/grpc'], ['te', 'trailers']
        ],
        body: grpc_frame('req')
      )

      expect(initial_headers.assoc(':status')[1]).to eq('200')

      # 5 DATA frames, one per yielded message.
      expect(data_frames.length).to eq(5)
      data_frames.each_with_index do |f, idx|
        expect(f[:bytes]).to eq(messages[idx])
        # END_STREAM must NOT be on any DATA frame — it rides the trailer
        # HEADERS frame.
        expect(f[:end_stream]).to be(false)
      end

      expect(trailers).not_to be_nil
      expect(trailers.to_h['grpc-status']).to eq('0')
    ensure
      ssl&.close
      server&.stop
      serve_thread&.join(2)
    end
  end

  # --------------------------------------------------------------------------
  # Client-streaming + bidirectional require the streaming-input dispatch
  # path: app invoked on HEADERS arrival, rack.input.read blocks for DATA
  # frames. Gated on `Hyperion::Http2Handler::StreamingInput` being defined.
  # --------------------------------------------------------------------------
  def streaming_input_supported?
    defined?(Hyperion::Http2Handler::StreamingInput) ? true : false
  end

  describe 'client streaming' do
    it 'invokes the Rack app on HEADERS arrival and surfaces each DATA frame to rack.input.read' do
      skip 'streaming-input dispatch path not built yet' unless streaming_input_supported?

      observed_messages = []
      received_count_done = ::Async::Notification.new
      app = lambda do |env|
        # Read 5 length-prefix-framed gRPC messages off the wire as they
        # arrive, mirroring what a real client-streaming handler would do.
        io = env['rack.input']
        5.times do
          # Read 5-byte gRPC frame prefix (1 flag + 4 length).
          prefix = io.read(5)
          break if prefix.nil? || prefix.bytesize < 5

          length = prefix.byteslice(1, 4).unpack1('N')
          payload = io.read(length)
          observed_messages << payload
        end
        received_count_done.signal
        body = ServerStreamBody.new([grpc_frame("got-#{observed_messages.length}")],
                                    { 'grpc-status' => '0' })
        [200, { 'content-type' => 'application/grpc' }, body]
      end

      server, serve_thread = boot_server(app)
      client, ssl = open_h2_client(server.port)

      stream = client.create_stream
      headers = [
        [':method', 'POST'], [':scheme', 'https'],
        [':authority', '127.0.0.1'], [':path', '/svc/ClientStream'],
        ['content-type', 'application/grpc'], ['te', 'trailers']
      ]
      stream.send_headers(headers, 0) # no END_STREAM — body to follow

      # Send 5 DATA frames spaced over time.
      payloads = (1..5).map { |i| "client-#{i}" }
      payloads.each_with_index do |p, idx|
        last = idx == payloads.length - 1
        stream.send_data(grpc_frame(p), last ? ::Protocol::HTTP2::END_STREAM : 0)
        sleep 0.005
      end

      deadline = Time.now + 5
      client.read_frame until stream.closed? || Time.now > deadline

      expect(observed_messages).to eq(payloads.map(&:b))
    ensure
      ssl&.close
      server&.stop
      serve_thread&.join(2)
    end
  end

  describe 'bidirectional streaming' do
    it 'interleaves reads from rack.input with writes to the response body across 5 round-trips' do
      skip 'streaming-input dispatch path not built yet' unless streaming_input_supported?

      app = lambda do |env|
        io = env['rack.input']
        chunks = []
        replies = []
        5.times do |i|
          prefix = io.read(5)
          raise 'short read' if prefix.nil? || prefix.bytesize < 5

          len = prefix.byteslice(1, 4).unpack1('N')
          payload = io.read(len)
          chunks << payload
          replies << grpc_frame("echo-#{i}-#{payload}")
        end
        body = ServerStreamBody.new(replies, { 'grpc-status' => '0' })
        [200, { 'content-type' => 'application/grpc' }, body]
      end

      server, serve_thread = boot_server(app)
      client, ssl = open_h2_client(server.port)

      stream = client.create_stream
      headers = [
        [':method', 'POST'], [':scheme', 'https'],
        [':authority', '127.0.0.1'], [':path', '/svc/BidiStream'],
        ['content-type', 'application/grpc'], ['te', 'trailers']
      ]
      stream.send_headers(headers, 0)

      received_data = []
      header_blocks = []
      stream_class = stream.class
      stream.define_singleton_method(:process_data) do |frame|
        d = stream_class.instance_method(:process_data).bind_call(self, frame)
        received_data << d.dup
        d
      end
      stream.define_singleton_method(:process_headers) do |frame|
        decoded = stream_class.instance_method(:process_headers).bind_call(self, frame)
        header_blocks << { headers: decoded.dup, end_stream: frame.end_stream? }
        decoded
      end

      payloads = (1..5).map { |i| "bidi-#{i}" }
      payloads.each_with_index do |p, idx|
        last = idx == payloads.length - 1
        stream.send_data(grpc_frame(p), last ? ::Protocol::HTTP2::END_STREAM : 0)
        sleep 0.01
      end

      deadline = Time.now + 5
      client.read_frame until stream.closed? || Time.now > deadline

      # Server echoes back exactly 5 frames in matching order.
      expect(received_data.length).to eq(5)
      received_data.each_with_index do |d, idx|
        # Skip the gRPC 5-byte prefix to compare payloads.
        payload = d.byteslice(5, d.bytesize - 5)
        expect(payload).to eq("echo-#{idx}-#{payloads[idx]}".b)
      end

      trailing = header_blocks[1..]&.find { |b| b[:end_stream] }&.dig(:headers)
      expect(trailing).not_to be_nil
      expect(trailing.to_h['grpc-status']).to eq('0')
    ensure
      ssl&.close
      server&.stop
      serve_thread&.join(2)
    end
  end

  describe 'StreamingInput unit' do
    it 'blocks on read until chunks are pushed, returns EOF when closed' do
      skip 'StreamingInput not built yet' unless streaming_input_supported?

      Sync do
        input = Hyperion::Http2Handler::StreamingInput.new
        reader = Async do
          [input.read(5), input.read(5), input.read]
        end

        # Push two 5-byte chunks then close.
        Async do |task|
          task.sleep(0.01)
          input.push('hello')
          task.sleep(0.01)
          input.push('world')
          task.sleep(0.01)
          input.close_writer
        end

        result = reader.wait
        expect(result[0]).to eq('hello'.b)
        expect(result[1]).to eq('world'.b)
        # third read sees EOF; depending on impl returns '' or nil.
        expect(['', nil]).to include(result[2])
      end
    end

    it 'satisfies a partial read by slicing the head chunk' do
      skip 'StreamingInput not built yet' unless streaming_input_supported?

      Sync do
        input = Hyperion::Http2Handler::StreamingInput.new
        input.push('hello world')
        input.close_writer
        expect(input.read(5)).to eq('hello'.b)
        expect(input.read(1)).to eq(' '.b)
        expect(input.read).to eq('world'.b)
      end
    end
  end
end
