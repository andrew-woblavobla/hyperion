# frozen_string_literal: true

require 'hyperion'

# 2.13-B — direct unit coverage for `Hyperion::CParser.build_response_head`.
#
# This is the C-side response-head builder that `ResponseWriter#build_head`
# delegates to when the C extension is loaded. The 2.13-B optimisations
# introduced three caches (status-line, per-key downcase, full-line) that
# need to keep behaving correctly across:
#   * repeated calls with the same frozen-literal Hash
#   * calls where the value changes between requests for the same key
#   * mixed-frozen and non-frozen header values
#   * unknown statuses + reasons (must NOT hit the static table)
#   * CRLF in header values (response-splitting guard)
#   * uppercase header keys (downcase normalisation)
RSpec.describe 'Hyperion::CParser.build_response_head' do
  let(:date_str) { 'Wed, 01 Jan 2026 12:00:00 GMT' }

  def call(headers, status: 200, reason: 'OK', body_size: 0, keep_alive: true)
    Hyperion::CParser.build_response_head(status, reason, headers, body_size, keep_alive, date_str)
  end

  it 'emits the canonical status line + framing for a vanilla 200' do
    head = call({}, body_size: 5)

    expect(head).to start_with("HTTP/1.1 200 OK\r\n")
    expect(head).to include("content-length: 5\r\n")
    expect(head).to include("connection: keep-alive\r\n")
    expect(head).to include("date: #{date_str}\r\n")
    expect(head).to end_with("\r\n\r\n")
  end

  it 'falls back to snprintf for unknown statuses' do
    head = call({}, status: 599, reason: 'Custom Reason')
    expect(head).to start_with("HTTP/1.1 599 Custom Reason\r\n")
  end

  it 'falls back to snprintf when the reason phrase is non-default for a known status' do
    head = call({}, status: 200, reason: 'Totally OK')
    expect(head).to start_with("HTTP/1.1 200 Totally OK\r\n")
  end

  it 'lowercases uppercase header keys' do
    head = call({ 'Content-Type' => 'text/plain' })
    expect(head).to include("content-type: text/plain\r\n")
  end

  it 'caches lowercase form of frozen-literal keys without changing wire output across calls' do
    headers = { 'content-type' => 'application/json', 'cache-control' => 'no-store' }
    h1 = call(headers, body_size: 10)
    h2 = call(headers, body_size: 10)
    expect(h1).to eq(h2)
    expect(h1).to include("content-type: application/json\r\n")
    expect(h1).to include("cache-control: no-store\r\n")
  end

  it 'updates the wire when the same key is reused with a different value' do
    h1 = call({ 'x-state' => 'a' })
    h2 = call({ 'x-state' => 'b' })

    expect(h1).to include("x-state: a\r\n")
    expect(h2).to include("x-state: b\r\n")
    expect(h1).not_to include("x-state: b\r\n")
    expect(h2).not_to include("x-state: a\r\n")
  end

  it 'updates the wire when the value Hash mutates between calls' do
    headers = { 'x-counter' => '1' }
    h1 = call(headers)

    headers['x-counter'] = '2'
    h2 = call(headers)

    expect(h1).to include("x-counter: 1\r\n")
    expect(h2).to include("x-counter: 2\r\n")
  end

  it 'emits content-length via the hand-rolled itoa for various sizes' do
    expect(call({}, body_size: 0)).to       include("content-length: 0\r\n")
    expect(call({}, body_size: 1)).to       include("content-length: 1\r\n")
    expect(call({}, body_size: 9)).to include("content-length: 9\r\n")
    expect(call({}, body_size: 10)).to    include("content-length: 10\r\n")
    expect(call({}, body_size: 99)).to    include("content-length: 99\r\n")
    expect(call({}, body_size: 100)).to include("content-length: 100\r\n")
    expect(call({}, body_size: 12_345)).to include("content-length: 12345\r\n")
    expect(call({}, body_size: 1_234_567_890)).to include("content-length: 1234567890\r\n")
  end

  it 'rejects header values containing CR/LF on first call' do
    expect do
      call({ 'x-evil' => "ok\r\nset-cookie: pwn=1" })
    end.to raise_error(ArgumentError, %r{CR/LF})
  end

  it 'rejects header values containing CR/LF AFTER a benign call cached the key prefix' do
    # Warm the per-key downcase cache with a benign value.
    call({ 'x-trace' => 'safe' })
    expect do
      call({ 'x-trace' => "evil\r\ninjected" })
    end.to raise_error(ArgumentError, %r{CR/LF})
  end

  it 'still rejects CRLF when the (key, value) full-line cache could erroneously rewarm' do
    # First call seeds the full-line cache with a safe pair.
    call({ 'x-pair' => 'safe' })

    # Reuse the same key with a malicious value — the (key, val) cache
    # MUST miss because the value differs, and we MUST re-validate.
    expect do
      call({ 'x-pair' => "evil\rval" })
    end.to raise_error(ArgumentError, %r{CR/LF})
  end

  it 'drops user-supplied content-length and emits the framing one' do
    head = call({ 'content-length' => '999' }, body_size: 7)
    expect(head).to include("content-length: 7\r\n")
    expect(head).not_to include("content-length: 999\r\n")
    expect(head.scan(/^content-length:/i).count).to eq(1)
  end

  it 'drops user-supplied connection and emits the framing one' do
    head = call({ 'connection' => 'close' }, keep_alive: true)
    expect(head).to include("connection: keep-alive\r\n")
    expect(head.scan(/^connection:/i).count).to eq(1)
  end

  it 'lets the app override the Date header' do
    head = call({ 'date' => 'Mon, 01 Jan 2026 00:00:00 GMT' })
    expect(head).to include("date: Mon, 01 Jan 2026 00:00:00 GMT\r\n")
    expect(head).not_to include("date: #{date_str}\r\n")
  end

  it 'emits Connection: close when keep_alive is false' do
    head = call({}, keep_alive: false)
    expect(head).to include("connection: close\r\n")
  end

  it 'covers every status in ResponseWriter::REASONS without snprintf fallback' do
    Hyperion::ResponseWriter::REASONS.each do |status, reason|
      head = call({}, status: status, reason: reason)
      expect(head).to start_with("HTTP/1.1 #{status} #{reason}\r\n"),
                      "expected pre-baked status line for #{status} #{reason.inspect}, got #{head[0, 32].inspect}"
    end
  end

  it 'preserves header value bytes verbatim (does not lowercase values)' do
    head = call({ 'x-trace-id' => 'AbCdEF-123' })
    expect(head).to include("x-trace-id: AbCdEF-123\r\n")
  end

  it 'handles mixed frozen + non-frozen values in one call' do
    frozen   = 'application/json' # frozen by frozen_string_literal: true
    dynamic  = +"id-#{rand(1000)}"
    head = call({ 'content-type' => frozen, 'x-dyn' => dynamic })

    expect(head).to include("content-type: #{frozen}\r\n")
    expect(head).to include("x-dyn: #{dynamic}\r\n")
  end

  it 'handles an empty headers Hash' do
    head = call({}, body_size: 0)
    expect(head).to start_with("HTTP/1.1 200 OK\r\n")
    expect(head).to end_with("\r\n\r\n")
    expect(head).to include("content-length: 0\r\n")
  end

  describe 'chunked-encoding sentinel (body_size = -1)' do
    it 'emits transfer-encoding: chunked instead of content-length' do
      head = call({ 'content-type' => 'text/plain' }, body_size: -1)
      expect(head).to start_with("HTTP/1.1 200 OK\r\n")
      expect(head).to include("transfer-encoding: chunked\r\n")
      expect(head).not_to include('content-length:')
      expect(head).to include("content-type: text/plain\r\n")
      expect(head).to end_with("\r\n\r\n")
    end

    it 'drops a caller-supplied transfer-encoding header (we always emit chunked)' do
      head = call({ 'transfer-encoding' => 'gzip' }, body_size: -1)
      expect(head).to include("transfer-encoding: chunked\r\n")
      expect(head).not_to include('transfer-encoding: gzip')
    end

    it 'drops a caller-supplied content-length header' do
      head = call({ 'content-length' => '99' }, body_size: -1)
      expect(head).to include("transfer-encoding: chunked\r\n")
      expect(head).not_to include('content-length:')
    end

    it 'survives the full-line cache: a non-chunked TE-cached entry is skipped in chunked mode' do
      # First populate the full-line cache with a frozen TE entry via a
      # non-chunked call. Then re-issue a chunked call carrying the same
      # TE; the chunked branch must skip the cached non-chunked TE line
      # and emit the canonical chunked line instead.
      frozen_te = -'identity'
      call({ 'transfer-encoding' => frozen_te }, body_size: 5)
      head = call({ 'transfer-encoding' => frozen_te }, body_size: -1)
      expect(head).to include("transfer-encoding: chunked\r\n")
      expect(head).not_to include('transfer-encoding: identity')
    end

    it 'raises ArgumentError for body_size < -1 (programming-error guard)' do
      expect {
        call({ 'content-type' => 'text/plain' }, body_size: -2)
      }.to raise_error(ArgumentError, /body_size must be >= 0/)
    end
  end

  it 'survives a stress loop over many distinct (key, value) pairs without corrupting earlier entries' do
    # Drive the full-line cache toward saturation. After saturation the
    # cache stops growing — which means new (k, v) pairs MUST still be
    # built correctly via the slow path. Older cached entries are
    # untouched.
    100.times do |i|
      head = call({ "x-stress-#{i}" => "v-#{i}" })
      expect(head).to include("x-stress-#{i}: v-#{i}\r\n")
    end

    # Re-call early entries — they should still be served correctly
    # (either from cache or by re-walk). Wire bytes match.
    head = call({ 'x-stress-0' => 'v-0' })
    expect(head).to include("x-stress-0: v-0\r\n")
  end
end
