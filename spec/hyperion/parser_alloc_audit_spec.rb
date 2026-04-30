# frozen_string_literal: true

# 2.4-B — per-parse allocation regression guard.
#
# CParser#parse went from ~19 obj/parse (1-header GET) and ~27
# obj/parse (4-chunk POST) on 2.3.0 to ~9 / ~16 respectively after
# 2.4-B-S1 (lazy field allocation) + S2 (pre-interned smuggling-defense
# keys). The thresholds are set ~25% above the post-fix numbers so a
# regression that re-introduces a per-parse String allocation trips
# the spec while normal runtime noise (Ruby version drift, GC cycle
# placement) stays green.

require 'hyperion'

RSpec.describe '2.4-B CParser allocation audit' do
  let(:parser) { Hyperion::CParser.new }

  def per_parse_allocations(buffer, iterations: 5_000, warmup: 500)
    warmup.times { parser.parse(buffer) }
    GC.disable
    GC.start
    before = GC.stat(:total_allocated_objects)
    iterations.times { parser.parse(buffer) }
    after = GC.stat(:total_allocated_objects)
    GC.enable
    (after - before).fdiv(iterations)
  end

  it 'allocates <= 12 objects per minimal GET (post 2.4-B target ~9)' do
    req = "GET / HTTP/1.1\r\nhost: x\r\n\r\n".b
    per = per_parse_allocations(req)
    expect(per).to be <= 12.0,
                   "expected <= 12 obj/parse for minimal GET, got #{per.round(2)}"
  end

  it 'allocates <= 22 objects per 5-header GET (post 2.4-B target ~18)' do
    req = "GET /a?q=1 HTTP/1.1\r\nhost: x\r\nuser-agent: bench\r\n" \
          "accept: */*\r\nconnection: keep-alive\r\ncookie: a=1; b=2\r\n\r\n".b
    per = per_parse_allocations(req)
    expect(per).to be <= 22.0,
                   "expected <= 22 obj/parse for 5-header GET, got #{per.round(2)}"
  end

  it 'allocates <= 20 objects per 4-chunk chunked POST (post 2.4-B target ~16)' do
    body = "40\r\n#{'a' * 64}\r\n40\r\n#{'b' * 64}\r\n40\r\n#{'c' * 64}\r\n40\r\n#{'d' * 64}\r\n0\r\n\r\n"
    req = "POST /upload HTTP/1.1\r\nhost: x\r\ntransfer-encoding: chunked\r\n\r\n#{body}".b
    per = per_parse_allocations(req)
    expect(per).to be <= 20.0,
                   "expected <= 20 obj/parse for chunked POST, got #{per.round(2)}"
  end

  it 'reuses the pre-interned EMPTY_STR / HTTP/1.1 constants in returned Request' do
    req = "GET / HTTP/1.1\r\nhost: x\r\n\r\n".b
    request, = parser.parse(req)
    # 2.4-B (S1): the lazy-Qnil path coerces unset fields to a single
    # frozen empty String global. Expose-as-frozen is the observable
    # invariant — identity is implementation detail but checking it
    # catches a regression where the frozen-empty path is bypassed.
    expect(request.body).to eq('')
    expect(request.body).to be_frozen
    expect(request.query_string).to eq('')
    expect(request.query_string).to be_frozen
    expect(request.http_version).to eq('HTTP/1.1')
    expect(request.http_version).to be_frozen
  end
end
