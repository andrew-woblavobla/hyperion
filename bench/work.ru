# frozen_string_literal: true

# CPU-bound benchmark: realistic per-request work (JSON serialization of a
# 50-key payload, header parsing with multiple cookies, optional body parsing).
# This exposes Hyperion's per-request CPU savings (lock-free metrics, C-ext
# response head, cached date, frozen header keys) which a `SELECT 1` workload
# hides behind network round-trip noise.
#
# 2.14-A — registered via the block form of `Server.handle` so the
# C accept loop dispatches: accept + recv + parse + write release the
# GVL, only the JSON-generate work itself holds it. The Rack `run`
# lambda below stays as the fallback for any path NOT registered
# (smoke harnesses hitting alternate URLs).
#
# To run:
#   bundle exec bin/hyperion -w 4 -t 5 -p 9292 bench/work.ru
#   wrk -t4 -c200 -d15s -H 'Cookie: a=1; b=2; c=3; d=4; e=5; f=6' \
#     http://127.0.0.1:9292/
require 'hyperion'
require 'json'

PAYLOAD = (1..50).each_with_object({}) do |i, h|
  h["key_#{i}"] = {
    id: i,
    name: "item-#{i}",
    description: "Item number #{i} with some descriptive text",
    score: i * 1.234,
    tags: %w[alpha beta gamma delta],
    active: i.even?
  }
end.freeze

PAYLOAD_JSON_BYTES = JSON.generate(PAYLOAD).bytesize

WORK_HANDLER = lambda do |env|
  # Force the Rack adapter to actually look at headers (cookies / accept) so
  # any header-handling cost shows up.
  cookie_count = env['HTTP_COOKIE'].to_s.count(';') + 1
  accept = env['HTTP_ACCEPT'] || '*/*'

  # Allocate a fresh response Hash (so Hash#to_json work isn't constant-folded
  # by the JIT). The 50-key fixture itself is frozen.
  body = JSON.generate(
    request_id: env['HTTP_X_REQUEST_ID'] || 'none',
    cookie_count: cookie_count,
    accept: accept,
    items: PAYLOAD
  )

  [
    200,
    {
      'content-type' => 'application/json',
      'cache-control' => 'no-store',
      'x-payload-size' => body.bytesize.to_s,
      'x-request-id' => env['HTTP_X_REQUEST_ID'] || 'none'
    },
    [body]
  ]
end

Hyperion::Server.handle(:GET, '/', &WORK_HANDLER)

run WORK_HANDLER
