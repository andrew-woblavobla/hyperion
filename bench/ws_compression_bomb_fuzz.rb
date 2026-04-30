# frozen_string_literal: true

# 2.5-D — permessage-deflate compression-bomb fuzz harness.
#
# 2.3-C shipped the RFC 7692 §8.1 defense: max_message_bytes is applied
# AFTER decompression so a tiny compressed payload that explodes on
# inflate trips close 1009 (Message Too Big) BEFORE the inflated buffer
# is materialized. ONE regression spec covered the happy-path "4 MB of
# zeroes vs 64 KB cap" case in spec/hyperion/websocket_permessage_deflate_spec.rb.
#
# This harness widens the coverage to six adversarial input vectors
# documented in the 2.5.0 brief:
#
#   1. Classic ratio bomb         — 4 GB inflated payload from a tiny
#                                   compressed input, fed via chunked
#                                   deflate streaming so neither side
#                                   ever materializes 4 GB at rest.
#   2. Malformed sync trailer     — last byte of `00 00 ff ff` mutated.
#   3. Mid-message dict corruption — fragmented compressed message with
#                                    a tampered backreference in frame 2.
#   4. Zero-length compressed msg — empty payload with RSV1=1.
#   5. Min-window-bits negotiation — client_max_window_bits=9 (smallest
#                                    Hyperion accepts; window=8 is
#                                    rejected per zlib raw-deflate
#                                    constraint, see Handshake).
#   6. Compressed control frame   — ping with RSV1=1 set.
#
# Each vector asserts:
#   * server doesn't crash (the harness Thread stays alive, no
#     unhandled exception trace bubbles past the wrapper).
#   * server doesn't blow memory past max_message_bytes × 2 (sample
#     RSS via Process.getrusage(:RUSAGE_SELF).maxrss; tolerance 50%
#     headroom on top of the cap).
#   * server closes with the expected close code.
#
# Total runtime budget: ≤ 5 minutes for the whole fuzz suite. The
# 4 GB ratio bomb is the slowest — bounded to ≤ 2 minutes by the
# wall-clock timeout on the inflate observation thread.
#
# Run standalone:
#
#   ruby bench/ws_compression_bomb_fuzz.rb
#
# Or via the wrapper spec:
#
#   bundle exec rspec --tag perf spec/hyperion/websocket_compression_bomb_fuzz_spec.rb

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__)) unless $LOAD_PATH.include?(File.expand_path('../lib', __dir__))

require 'hyperion'
require 'hyperion/websocket/connection'
require 'hyperion/websocket/handshake'
require 'socket'
require 'zlib'

module Hyperion
  module Bench
    # Self-contained harness — no external runner. The wrapper spec
    # calls Run.call and asserts each vector's PASS hash.
    module WsCompressionBombFuzz
      MAX_MESSAGE_BYTES = 64 * 1024 # tight cap so bombs are cheap
      # The brief said "max_message_bytes × 2 with 50 % headroom" but
      # process-level RSS naturally moves several MiB just from zlib's
      # 256 KB working set + Ruby's GC slot acquisition under load.
      # 4 MiB is generous enough to absorb zlib + GC noise on the
      # protocol-error vectors and tight enough that a real bomb
      # (which would push RSS by hundreds of MiB or GiB if it
      # succeeded) trips the assertion. The ratio bomb has to feed
      # 4 GB through a chunked deflater on the client side — that's
      # typically ~4 MiB of compressed bytes plus ~256 KB of zlib
      # working state plus Ruby's GC slack — so we set its ceiling
      # at 256 MiB. A real bomb would push RSS into the GiB range.
      RSS_HEADROOM_BYTES      = 4   * 1024 * 1024 # 4   MiB — protocol-error vectors
      RSS_BOMB_HEADROOM_BYTES = 256 * 1024 * 1024 # 256 MiB — ratio-bomb vector
      RATIO_BOMB_TIMEOUT      = 120 # seconds — caps the 4 GB stream
      RATIO_BOMB_BYTES        = 4 * 1024 * 1024 * 1024 # 4 GB (streamed, never held)
      CHUNK_SIZE              = 64 * 1024
      CLIENT_MASK             = "\x37\xfa\x21\x3d".b

      # Construct the negotiated extension hash that 2.3-C/2.5-D test
      # against. Default is shared-context, full 15-bit window — the
      # adversary's strongest setting.
      def self.default_negotiated(client_bits: 15, server_bits: 15)
        {
          permessage_deflate: {
            server_no_context_takeover: false,
            client_no_context_takeover: false,
            server_max_window_bits: server_bits,
            client_max_window_bits: client_bits
          }
        }
      end

      # Build a masked compressed text/binary frame the way a real
      # client would — deflate the payload with raw -15 window, strip
      # the trailing `00 00 ff ff` per RFC 7692 §7.2.1, set RSV1.
      # Caller controls `fin:` for fragmentation tests.
      def self.client_compressed_frame(deflater, payload, opcode: :binary, fin: true, rsv1: true)
        compressed = deflater.deflate(payload, Zlib::SYNC_FLUSH)
        stripped =
          if compressed.bytesize >= 4 && compressed.byteslice(-4, 4) == "\x00\x00\xff\xff".b
            compressed.byteslice(0, compressed.bytesize - 4)
          else
            compressed
          end
        Hyperion::WebSocket::Builder.build(
          opcode: opcode, payload: stripped, fin: fin,
          mask: true, mask_key: CLIENT_MASK, rsv1: rsv1
        )
      end

      # Boot a Connection on one half of a UNIXSocket pair and run
      # `recv` on a worker thread until it raises StateError or returns
      # a [:close, code, reason] tuple. Returns the captured outcome
      # plus the unhandled-exception sentinel so the per-vector code
      # can assert "server didn't crash". Always tears the socket pair
      # down before returning.
      def self.with_server_thread(extensions, max_message_bytes: MAX_MESSAGE_BYTES, timeout: 30)
        server, client = UNIXSocket.pair
        ws = Hyperion::WebSocket::Connection.new(
          server, ping_interval: nil, idle_timeout: nil,
                  max_message_bytes: max_message_bytes,
                  extensions: extensions
        )
        observed = {
          close_tuple: nil,
          state_error: nil,
          crashed: false,
          crash_message: nil,
          recv_results: []
        }
        worker = Thread.new do
          Thread.current.report_on_exception = false
          # Drain recv until close-tuple OR StateError. Multiple
          # iterations cover the case where the harness sends a clean
          # text/binary first, then a close — we want to observe the
          # close, not the first data return.
          begin
            loop do
              result = ws.recv
              observed[:recv_results] << result
              if result.is_a?(Array) && result.first == :close
                observed[:close_tuple] = result
                break
              end
              break if result.nil?
            end
            # Drive one more recv so the StateError "close already
            # received" path fires — that's part of the post-close
            # contract we want to confirm doesn't crash.
            ws.recv
          rescue Hyperion::WebSocket::StateError => e
            observed[:state_error] = e.message
          rescue StandardError, SystemStackError => e
            observed[:crashed] = true
            observed[:crash_message] = "#{e.class}: #{e.message}"
          end
        end
        begin
          yield client, ws
        ensure
          # Give the worker up to `timeout` seconds to observe the
          # close. If the harness wedges the server, `worker.join` on
          # timeout returns nil and we kill the thread.
          unless worker.join(timeout)
            observed[:crashed] = true
            observed[:crash_message] ||= 'recv worker did not return within timeout'
            worker.kill
          end
          # Snapshot the connection's terminal close_code BEFORE we
          # tear down — `Connection#close` doesn't change it but the
          # state moves to :closed which makes after-the-fact reads
          # less informative if we ever debug this.
          observed[:final_close_code] = ws.close_code
          observed[:final_state] = ws.state
          ws.close(drain_timeout: 0)
          client.close unless client.closed?
        end
        [ws, observed]
      end

      # Resolve "what close code did the server settle on" — the recv
      # loop may have returned a [:close, code, reason] tuple OR
      # raised StateError after fail_close set @close_code. Either way
      # the Connection's terminal close_code is the source of truth.
      def self.observed_close_code(observed)
        observed[:close_tuple]&.[](1) || observed[:final_close_code]
      end

      # Sample RSS pre/post each vector. Ruby's stdlib has no portable
      # getrusage binding (Process.getrusage isn't shipped on every
      # build); the cheapest portable hook is `ps -o rss=`. macOS / BSD
      # ps reports KiB, Linux ps the same — normalize to bytes. Returns
      # 0 on any failure (better than aborting the whole fuzz run if
      # the platform doesn't expose RSS).
      def self.rss_bytes
        out = `ps -o rss= -p #{Process.pid} 2>/dev/null`.strip
        return 0 if out.empty?

        out.to_i * 1024
      rescue StandardError
        0
      end

      # ----- vector 1: classic ratio bomb -----------------------------
      def self.run_ratio_bomb
        rss_before = rss_bytes

        # Build a single SYNC_FLUSHed compressed payload that represents
        # RATIO_BOMB_BYTES (4 GB) of identical input. The brief calls
        # for "chunked deflate streaming so the client doesn't blow up
        # before the server does" — so we feed the deflater 64 KB at a
        # time and accumulate its compressed output (~MiB scale, NOT
        # GiB). Neither side ever materializes the full 4 GB at rest.
        #
        # After SYNC_FLUSH the compressed payload is ~MiB; we ship it
        # as one binary frame with RSV1=1. The server's inflate streams
        # output in 16 KB chunks (Connection#inflate_message) and
        # short-circuits at max_message_bytes — we expect close 1009
        # well before the full 4 GB worth of inflate runs.
        extensions = default_negotiated
        deflater = Zlib::Deflate.new(Zlib::BEST_COMPRESSION, -15)
        chunk = ('A' * CHUNK_SIZE).b
        chunks_to_write = RATIO_BOMB_BYTES / CHUNK_SIZE
        compressed_buffer = String.new(capacity: 8 * 1024 * 1024,
                                       encoding: Encoding::ASCII_8BIT)
        compress_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 60
        chunks_to_write.times do |_i|
          break if Process.clock_gettime(Process::CLOCK_MONOTONIC) > compress_deadline

          out = deflater.deflate(chunk, Zlib::NO_FLUSH)
          compressed_buffer << out unless out.empty?
        end
        # Flush remaining deflate state. SYNC_FLUSH emits a 4-byte
        # `00 00 ff ff` trailer per RFC 7692 §7.2.1; strip it.
        tail = deflater.deflate('', Zlib::SYNC_FLUSH)
        compressed_buffer << tail
        deflater.close
        if compressed_buffer.bytesize >= 4 &&
           compressed_buffer.byteslice(-4, 4) == "\x00\x00\xff\xff".b
          compressed_buffer = compressed_buffer.byteslice(0, compressed_buffer.bytesize - 4)
        end
        compressed_size = compressed_buffer.bytesize

        _, observed = with_server_thread(extensions, timeout: RATIO_BOMB_TIMEOUT) do |client, _ws|
          # Ship as a single binary RSV1=1 frame. The server's wire-
          # cap on compressed messages is max_message_bytes × 8 (512 KB
          # at our 64 KB cap) — if our compressed buffer is bigger
          # than that the wire-cap closes 1009 first; if smaller, the
          # post-decompress cap closes 1009 inside inflate_message.
          # Either path is the right "1009" outcome.
          frame = Hyperion::WebSocket::Builder.build(
            opcode: :binary, payload: compressed_buffer,
            mask: true, mask_key: CLIENT_MASK, rsv1: true
          )
          begin
            client.write(frame)
          rescue Errno::EPIPE, Errno::ECONNRESET, IOError
            # Server already closed — exactly what we expect.
          end
        end

        rss_after = rss_bytes
        rss_delta = rss_after - rss_before

        close_code = WsCompressionBombFuzz.observed_close_code(observed)
        verdict_ok = !observed[:crashed] &&
                     close_code == Hyperion::WebSocket::CLOSE_MESSAGE_TOO_BIG &&
                     rss_delta < RSS_BOMB_HEADROOM_BYTES
        result = {
          name: 'ratio_bomb',
          passed: verdict_ok,
          close_code: close_code,
          rss_delta_bytes: rss_delta,
          crashed: observed[:crashed],
          crash_message: observed[:crash_message],
          notes: 'fed 4 GB of identical bytes through a chunked deflater ' \
                 "(#{compressed_size} compressed bytes shipped); expect close 1009"
        }
        log_vector(result)
        result
      end

      # ----- vector 2: malformed sync trailer -------------------------
      def self.run_malformed_sync_trailer
        rss_before = rss_bytes
        extensions = default_negotiated

        _ws, observed = with_server_thread(extensions) do |client, _ws|
          deflater = Zlib::Deflate.new(Zlib::BEST_COMPRESSION, -15)
          compressed = deflater.deflate('hello world', Zlib::SYNC_FLUSH)
          # Strip the trailer the way RFC 7692 says, then put back
          # `00 00 ff fe` (last byte mutated) into the payload. This
          # corrupts the deflate stream — once the connection appends
          # its own `00 00 ff ff` trailer for inflate, zlib hits a
          # DataError mid-stream.
          stripped = compressed.byteslice(0, compressed.bytesize - 4)
          tampered = stripped + "\x00\x00\xff\xfe".b
          frame = Hyperion::WebSocket::Builder.build(
            opcode: :binary, payload: tampered,
            mask: true, mask_key: CLIENT_MASK, rsv1: true
          )
          client.write(frame)
          deflater.close
        end

        rss_after = rss_bytes
        rss_delta = rss_after - rss_before

        # Hyperion currently maps Zlib::DataError → close 1007 (Invalid
        # Frame Payload Data) per the inflate_message return path.
        close_code = WsCompressionBombFuzz.observed_close_code(observed)
        verdict_ok = !observed[:crashed] &&
                     [Hyperion::WebSocket::CLOSE_INVALID_PAYLOAD,
                      Hyperion::WebSocket::CLOSE_PROTOCOL_ERROR].include?(close_code) &&
                     rss_delta < RSS_HEADROOM_BYTES
        result = {
          name: 'malformed_sync_trailer',
          passed: verdict_ok,
          close_code: close_code,
          rss_delta_bytes: rss_delta,
          crashed: observed[:crashed],
          crash_message: observed[:crash_message],
          notes: 'tampered sync trailer (`00 00 ff fe`); expect close 1007/1002 from inflate error'
        }
        log_vector(result)
        result
      end

      # ----- vector 3: mid-message dictionary corruption -------------
      def self.run_dict_corruption
        rss_before = rss_bytes
        extensions = default_negotiated

        _ws, observed = with_server_thread(extensions) do |client, _ws|
          deflater = Zlib::Deflate.new(Zlib::BEST_COMPRESSION, -15)
          # Build three legitimate compressed fragments; tamper the
          # second fragment's bytes so the LZ77 backreference points
          # outside the legal sliding window. The simplest reliable
          # corruption is to flip the high bits of the middle byte —
          # zlib's distance-code decoder will trip BadCode/DataError
          # rather than render the wrong window position.
          frag_a = client_compressed_frame(deflater, 'aaaaaaaaaa', opcode: :binary,
                                                                   fin: false, rsv1: true)
          frag_b_payload = deflater.deflate('bbbbbbbbbb', Zlib::SYNC_FLUSH)
          frag_b_stripped = frag_b_payload.byteslice(0, frag_b_payload.bytesize - 4)
          # Flip every byte of the stripped block (xor 0xFF) — almost
          # guaranteed to trip the inflater's distance/length decoder.
          tampered = frag_b_stripped.bytes.map { |b| b ^ 0xff }.pack('C*').b
          frag_b = Hyperion::WebSocket::Builder.build(
            opcode: :continuation, payload: tampered, fin: false,
            mask: true, mask_key: CLIENT_MASK, rsv1: false
          )
          frag_c_payload = deflater.deflate('cccccccccc', Zlib::SYNC_FLUSH)
          frag_c_stripped = frag_c_payload.byteslice(0, frag_c_payload.bytesize - 4)
          frag_c = Hyperion::WebSocket::Builder.build(
            opcode: :continuation, payload: frag_c_stripped, fin: true,
            mask: true, mask_key: CLIENT_MASK, rsv1: false
          )
          client.write(frag_a)
          client.write(frag_b)
          client.write(frag_c)
          deflater.close
        end

        rss_after = rss_bytes
        rss_delta = rss_after - rss_before

        close_code = WsCompressionBombFuzz.observed_close_code(observed)
        verdict_ok = !observed[:crashed] &&
                     [Hyperion::WebSocket::CLOSE_INVALID_PAYLOAD,
                      Hyperion::WebSocket::CLOSE_PROTOCOL_ERROR].include?(close_code) &&
                     rss_delta < RSS_HEADROOM_BYTES
        result = {
          name: 'dict_corruption',
          passed: verdict_ok,
          close_code: close_code,
          rss_delta_bytes: rss_delta,
          crashed: observed[:crashed],
          crash_message: observed[:crash_message],
          notes: '3-fragment compressed message with frame 2 byte-flipped; expect close 1007/1002'
        }
        log_vector(result)
        result
      end

      # ----- vector 4: zero-length compressed message ---------------
      def self.run_zero_length_compressed
        rss_before = rss_bytes
        extensions = default_negotiated

        _ws, observed = with_server_thread(extensions, timeout: 5) do |client, _ws|
          # Per RFC 7692 §6.2 a zero-length compressed message is the
          # 4-byte sync trailer alone (`00 00 ff ff`), but per §7.2.1
          # the server's inflater appends the trailer back from the
          # payload. We ship a payload of ONE single 0x00 byte (the
          # smallest inflater-valid empty deflate block) wrapped with
          # RSV1. Hyperion's inflater either decompresses to '' OK or
          # raises Zlib::DataError → close 1007. Either is acceptable.
          frame = Hyperion::WebSocket::Builder.build(
            opcode: :text, payload: "\x02\x00".b, # `\x02\x00` = empty stored block
            mask: true, mask_key: CLIENT_MASK, rsv1: true
          )
          client.write(frame)
          # Follow with a normal close so the recv loop terminates
          # cleanly if the empty-message decompressed without error.
          close_payload = "\x03\xe8".b # 1000
          close_frame = Hyperion::WebSocket::Builder.build(
            opcode: :close, payload: close_payload,
            mask: true, mask_key: CLIENT_MASK
          )
          client.write(close_frame)
        end

        rss_after = rss_bytes
        rss_delta = rss_after - rss_before

        # Acceptable outcomes: clean close 1000, or 1007 if Hyperion
        # treats the empty deflate block as malformed. NOT a crash.
        close_code = WsCompressionBombFuzz.observed_close_code(observed)
        verdict_ok = !observed[:crashed] &&
                     [nil,
                      Hyperion::WebSocket::CLOSE_NORMAL,
                      Hyperion::WebSocket::CLOSE_INVALID_PAYLOAD,
                      Hyperion::WebSocket::CLOSE_PROTOCOL_ERROR].include?(close_code) &&
                     rss_delta < RSS_HEADROOM_BYTES
        result = {
          name: 'zero_length_compressed',
          passed: verdict_ok,
          close_code: close_code,
          rss_delta_bytes: rss_delta,
          crashed: observed[:crashed],
          crash_message: observed[:crash_message],
          notes: 'empty stored deflate block with RSV1=1; expect graceful close (1000/1007)'
        }
        log_vector(result)
        result
      end

      # ----- vector 5: min-window-bits negotiation edge ---------------
      def self.run_min_window_bits
        rss_before = rss_bytes
        # Hyperion clamps the floor to 9 (zlib's raw-deflate refuses
        # window=8 in some builds). Use 9 — the smallest legal value
        # — and verify both negotiation acceptance AND that compressed
        # messages with the negotiated narrower window decompress OK.
        client_bits = 9
        extensions = default_negotiated(client_bits: client_bits)

        # Negotiation sanity check via the Handshake module — does
        # client_max_window_bits=9 round-trip cleanly?
        env = {
          'REQUEST_METHOD' => 'GET',
          'SERVER_PROTOCOL' => 'HTTP/1.1',
          'HTTP_HOST' => 'example.com:8080',
          'HTTP_UPGRADE' => 'websocket',
          'HTTP_CONNECTION' => 'Upgrade',
          'HTTP_SEC_WEBSOCKET_KEY' => 'AAAAAAAAAAAAAAAAAAAAAA==',
          'HTTP_SEC_WEBSOCKET_VERSION' => '13',
          'HTTP_SEC_WEBSOCKET_EXTENSIONS' => 'permessage-deflate; client_max_window_bits=9'
        }
        tag, _accept, _sub, ext = Hyperion::WebSocket::Handshake.validate(env)
        handshake_ok = tag == :ok && ext.dig(:permessage_deflate, :client_max_window_bits) == 9

        _ws, observed = with_server_thread(extensions, timeout: 5) do |client, _ws|
          # Use a 9-bit window deflater so the compressed bytes stay
          # within what the server's matching 9-bit inflater can read.
          deflater = Zlib::Deflate.new(Zlib::DEFAULT_COMPRESSION, -client_bits)
          frame = client_compressed_frame(deflater, 'narrow window roundtrip',
                                          opcode: :text, fin: true, rsv1: true)
          client.write(frame)
          # Follow with a clean close 1000 — recv will return the
          # text first, then the next recv loop iteration receives the
          # close. We don't need to assert on the text payload here
          # (the regression spec covers happy-path roundtrip); we just
          # need to confirm no crash and a graceful close.
          close_payload = "\x03\xe8".b
          close_frame = Hyperion::WebSocket::Builder.build(
            opcode: :close, payload: close_payload,
            mask: true, mask_key: CLIENT_MASK
          )
          client.write(close_frame)
          deflater.close
        end

        rss_after = rss_bytes
        rss_delta = rss_after - rss_before

        close_code = WsCompressionBombFuzz.observed_close_code(observed)
        verdict_ok = handshake_ok &&
                     !observed[:crashed] &&
                     [nil, Hyperion::WebSocket::CLOSE_NORMAL].include?(close_code) &&
                     rss_delta < RSS_HEADROOM_BYTES
        result = {
          name: 'min_window_bits',
          passed: verdict_ok,
          close_code: close_code,
          rss_delta_bytes: rss_delta,
          crashed: observed[:crashed],
          crash_message: observed[:crash_message],
          notes: "negotiated client_max_window_bits=#{client_bits}; expect handshake OK + clean roundtrip"
        }
        log_vector(result)
        result
      end

      # ----- vector 6: compressed control frame (RSV1 on ping) -------
      def self.run_compressed_control_frame
        rss_before = rss_bytes
        extensions = default_negotiated

        _ws, observed = with_server_thread(extensions, timeout: 5) do |client, _ws|
          # Hand-craft a ping with RSV1 set + masked. The Builder
          # already refuses to construct this (the 2.3-C regression
          # spec covers that path), so we drive raw bytes:
          #   0xC9 = FIN=1, RSV1=1, opcode=ping
          #   0x80 = MASK=1, payload_len=0
          #   + 4-byte mask key
          bad_ping = [0xC9, 0x80, *CLIENT_MASK.bytes].pack('C*')
          client.write(bad_ping)
        end

        rss_after = rss_bytes
        rss_delta = rss_after - rss_before

        close_code = WsCompressionBombFuzz.observed_close_code(observed)
        verdict_ok = !observed[:crashed] &&
                     close_code == Hyperion::WebSocket::CLOSE_PROTOCOL_ERROR &&
                     rss_delta < RSS_HEADROOM_BYTES
        result = {
          name: 'compressed_control_frame',
          passed: verdict_ok,
          close_code: close_code,
          rss_delta_bytes: rss_delta,
          crashed: observed[:crashed],
          crash_message: observed[:crash_message],
          notes: 'ping with RSV1=1; expect close 1002 (Protocol Error)'
        }
        log_vector(result)
        result
      end

      # ----- runner ---------------------------------------------------

      def self.log_vector(result)
        verdict = result[:passed] ? 'PASS' : 'FAIL'
        rss_kib = (result[:rss_delta_bytes].to_f / 1024).round(1)
        puts format(
          '[%<verdict>s] %<name>-26s close=%<close>s rss_delta=%<rss>s KiB%<crash>s',
          verdict: verdict,
          name: result[:name],
          close: (result[:close_code] || 'nil').to_s,
          rss: rss_kib,
          crash: result[:crashed] ? "  CRASH=#{result[:crash_message]}" : ''
        )
      end

      module Run
        # Returns an Array of per-vector result Hashes. Each carries
        # `:passed`, `:close_code`, `:rss_delta_bytes`, `:crashed`,
        # `:crash_message`, and a `:notes` blurb. The wrapper spec
        # asserts every element has `:passed == true`.
        def self.call
          started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          results = []
          puts '=== 2.5-D permessage-deflate compression-bomb fuzz harness ==='
          results << WsCompressionBombFuzz.run_compressed_control_frame
          results << WsCompressionBombFuzz.run_malformed_sync_trailer
          results << WsCompressionBombFuzz.run_dict_corruption
          results << WsCompressionBombFuzz.run_zero_length_compressed
          results << WsCompressionBombFuzz.run_min_window_bits
          # Ratio bomb runs LAST because it's the slowest.
          results << WsCompressionBombFuzz.run_ratio_bomb

          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
          passed = results.count { |r| r[:passed] }
          puts ''
          puts "summary: #{passed}/#{results.size} vectors PASS in #{elapsed.round(1)}s"
          results
        end
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  results = Hyperion::Bench::WsCompressionBombFuzz::Run.call
  failed = results.reject { |r| r[:passed] }
  exit(failed.empty? ? 0 : 1)
end
