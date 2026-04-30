# frozen_string_literal: true

# 2.4-B — WebSocket frame allocation regression guard.
#
# Locks the post-2.4-B-S4+S5 numbers for `Builder.build` (send hot path)
# and `Parser.parse` (recv hot path) so a regression that re-introduces
# a redundant `.b` clone or drops the frozen empty-payload sentinel
# trips the spec.

require 'hyperion'
require 'hyperion/websocket/frame'

RSpec.describe '2.4-B WebSocket frame allocation audit' do
  let(:payload_text) { 'hello world this is a sample chat message with normal length'.b }
  let(:payload_bin)  { ('A' * 256).b }
  let(:mask_key)     { "\x01\x02\x03\x04".b }

  def per_call_allocations(iterations: 5_000, warmup: 500, &block)
    warmup.times(&block)
    GC.disable
    GC.start
    before = GC.stat(:total_allocated_objects)
    iterations.times(&block)
    after = GC.stat(:total_allocated_objects)
    GC.enable
    (after - before).fdiv(iterations)
  end

  describe 'Builder.build' do
    it 'allocates <= 4 objects per unmasked binary send (S4 — skip redundant .b)' do
      per = per_call_allocations do
        Hyperion::WebSocket::Builder.build(opcode: :text, payload: payload_text)
      end
      # Post-S4: ~3 obj/call (the wire output String, mask_key Qnil
      # plumbing, kwargs hash). Threshold 4 absorbs Ruby-version noise
      # without letting a fresh `.b` clone slip back in (that would
      # bump to 5+).
      expect(per).to be <= 4.0,
                     "expected <= 4 obj/call for Builder.build unmasked, got #{per.round(2)}"
    end
  end

  describe 'Parser.parse' do
    it 'shares one frozen EMPTY_BIN_PAYLOAD across empty-payload frames (S5)' do
      empty_unmasked_frame = Hyperion::WebSocket::Builder.build(opcode: :ping, payload: '')
      f1 = Hyperion::WebSocket::Parser.parse(empty_unmasked_frame, 0)
      f2 = Hyperion::WebSocket::Parser.parse(empty_unmasked_frame, 0)
      # Identity: the same frozen binary String is reused, not freshly
      # allocated.
      expect(f1.payload).to be(f2.payload)
      expect(f1.payload).to be_frozen
      expect(f1.payload.encoding).to eq(Encoding::ASCII_8BIT)
    end

    it 'allocates <= 11 objects per masked text-frame parse' do
      frame = Hyperion::WebSocket::Builder.build(opcode: :text, payload: payload_text,
                                                 mask: true, mask_key: mask_key)
      per = per_call_allocations do
        Hyperion::WebSocket::Parser.parse(frame, 0)
      end
      # Post-2.4-B measured 10 obj/parse on the masked path: the C ext
      # returns an 8-element Array + mask_key String + unmask String;
      # the Ruby façade allocates a Frame Struct on top. Threshold 11
      # tracks that without flapping on noise; a regression that
      # re-introduces `.b` on the masked side would push to 12+.
      expect(per).to be <= 11.0,
                     "expected <= 11 obj/call for masked text parse, got #{per.round(2)}"
    end

    it 'allocates <= 9 objects per unmasked binary-frame parse (S5 — slice.b skipped)' do
      frame = Hyperion::WebSocket::Builder.build(opcode: :binary, payload: payload_bin)
      per = per_call_allocations do
        Hyperion::WebSocket::Parser.parse(frame, 0)
      end
      # Post-S5: ~8 obj/parse (8-tuple Array + Frame Struct + a few
      # internal). Threshold 9 catches a re-introduced `.b` clone
      # (would bump back to 9-10).
      expect(per).to be <= 9.0,
                     "expected <= 9 obj/call for unmasked binary parse, got #{per.round(2)}"
    end
  end
end
