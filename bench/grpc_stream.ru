# frozen_string_literal: true

# 2.13-D — Rack app exposing a server-streaming + unary gRPC service for
# the ghz bench. The proto is `bench/grpc_stream.proto`. We hand-roll the
# protobuf encoding (EchoReply { bytes payload = 1 }) because we don't
# want a hard dependency on `google-protobuf` for the bench config —
# Hyperion ships as a server, not a gRPC framework.
#
# Knobs (env-driven so the bench harness can A/B):
#   * `GRPC_STREAM_COUNT` — replies per server-stream request (default 100)
#   * `GRPC_PAYLOAD_BYTES` — bytes per EchoReply.payload (default 10)
$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'hyperion'

STREAM_COUNT  = Integer(ENV.fetch('GRPC_STREAM_COUNT', '100'))
PAYLOAD_BYTES = Integer(ENV.fetch('GRPC_PAYLOAD_BYTES', '10'))

# Protobuf wire encoding of `EchoReply { bytes payload = 1; }`.
#   field 1, wire-type 2 (LEN) = (1 << 3) | 2 = 0x0A
#   followed by varint length, followed by N bytes
def encode_reply(payload)
  bytes = payload.b
  length = bytes.bytesize
  # Varint encoding of `length`. For length < 128 this is one byte;
  # bigger payloads encode each 7-bit group with continuation bit.
  varint = +''.b
  v = length
  loop do
    b = v & 0x7F
    v >>= 7
    if v.zero?
      varint << b.chr
      break
    else
      varint << (b | 0x80).chr
    end
  end
  "\x0A".b + varint + bytes
end

# Wrap protobuf bytes in the gRPC frame header: 1-byte compression flag
# (0 = uncompressed) + 4-byte big-endian length-prefix.
def grpc_frame(proto_bytes)
  "\x00".b + [proto_bytes.bytesize].pack('N') + proto_bytes
end

PAYLOAD_BYTES_STRING = ('x' * PAYLOAD_BYTES).b.freeze
SINGLE_REPLY_FRAME   = grpc_frame(encode_reply(PAYLOAD_BYTES_STRING)).freeze
PRECOMPUTED_FRAMES   = Array.new(STREAM_COUNT) { SINGLE_REPLY_FRAME }.freeze

# Server-streaming response body: yields STREAM_COUNT pre-computed gRPC
# message frames via `each`, then exposes the standard gRPC trailers.
class ServerStreamBody
  TRAILERS = { 'grpc-status' => '0', 'grpc-message' => 'OK' }.freeze

  def each
    PRECOMPUTED_FRAMES.each { |f| yield f }
  end

  def trailers
    TRAILERS
  end

  def close; end
end

# Unary response body: one frame, same trailers shape.
class UnaryBody
  TRAILERS = ServerStreamBody::TRAILERS

  def initialize(frame); @frame = frame; end
  def each; yield @frame; end
  def trailers; TRAILERS; end
  def close; end
end

GRPC_HEADERS = { 'content-type' => 'application/grpc' }.freeze

run lambda { |env|
  path = env['PATH_INFO']
  # Drain the request body verbatim. ghz sends one EchoRequest message
  # per RPC; we don't bother decoding it since the response is fixed.
  env['rack.input']&.read

  case path
  when '/hyperion.bench.EchoStream/ServerStream'
    [200, GRPC_HEADERS, ServerStreamBody.new]
  when '/hyperion.bench.EchoStream/Unary'
    [200, GRPC_HEADERS, UnaryBody.new(SINGLE_REPLY_FRAME)]
  else
    # gRPC error: status 12 = UNIMPLEMENTED
    [200, GRPC_HEADERS, UnaryBody.new('').tap { |u|
      u.singleton_class.send(:define_method, :trailers) {
        { 'grpc-status' => '12', 'grpc-message' => 'Unimplemented' }
      }
    }]
  end
}
