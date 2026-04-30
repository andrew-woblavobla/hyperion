# frozen_string_literal: true

# Rails-shape h2 bench rackup. Mimics the response-header set a typical
# Rails 8.x app ships (~25 headers). Used by 2.5-B to measure HPACK
# encode CPU on a header-heavy workload — h2load `-c 1 -m 100 -n 5000`
# settles whether the v3 native HPACK adapter beats the Ruby fallback by
# >=15% on this shape (vs the parity it hit on hello.ru with 2 headers).
#
# Why a separate rackup. bench/hello.ru ships 2 response headers
# (content-type + content-length, the latter auto-inserted by the
# adapter). 2.4-A's HPACK FFI round-2 measured at parity on that shape
# because HPACK encode is <1% of per-stream CPU when there are ~2
# headers to encode. Real Rails apps ship 20–30 response headers
# (Rails defaults + ActionDispatch + ActionController + CSP/HSTS +
# request-id/runtime/cache-control). On that shape HPACK encode CPU
# climbs into the single-digit percent of per-stream CPU and the FFI
# marshalling overhead vs the native byte-pump matters.
#
# Body matches a typical Rails JSON response — small, ~200 bytes.
require 'json'
require 'securerandom'
require 'time'

BODY = JSON.generate({ status: 'ok', user: { id: 42, name: 'Alice', email: 'alice@example.com' } }).freeze

# 25 headers — ranges from Rails defaults (X-Frame-Options,
# X-Content-Type-Options, etc.) through ActionDispatch (X-Request-Id,
# X-Runtime) through CSP/HSTS to app-specific. Names are interned
# constants; values are mostly cacheable but X-Request-Id /
# Set-Cookie / ETag / CSP nonce vary per request (which is the
# realistic shape — most headers compress well via HPACK's dynamic
# table, the per-request varying ones don't).
def headers_for(env)
  rid = env['HTTP_X_REQUEST_ID'] || SecureRandom.uuid
  {
    'content-type'                => 'application/json; charset=utf-8',
    'x-frame-options'             => 'SAMEORIGIN',
    'x-xss-protection'            => '0',
    'x-content-type-options'      => 'nosniff',
    'x-permitted-cross-domain-policies' => 'none',
    'referrer-policy'             => 'strict-origin-when-cross-origin',
    'x-download-options'          => 'noopen',
    'cache-control'               => 'private, max-age=0, must-revalidate',
    'pragma'                      => 'no-cache',
    'expires'                     => 'Mon, 01 Jan 1990 00:00:00 GMT',
    'vary'                        => 'Accept, Accept-Encoding, Cookie',
    'content-language'            => 'en',
    'strict-transport-security'   => 'max-age=31536000; includeSubDomains; preload',
    'content-security-policy'     => "default-src 'self'; script-src 'self' 'nonce-#{rid[0, 8]}'; style-src 'self' 'unsafe-inline'",
    'x-request-id'                => rid,
    'x-runtime'                   => '0.012345',
    'x-powered-by'                => 'Hyperion',
    'set-cookie'                  => "_session_id=#{SecureRandom.hex(16)}; path=/; HttpOnly; SameSite=Lax",
    'etag'                        => "W/\"#{SecureRandom.hex(8)}\"",
    'last-modified'               => Time.now.utc.httpdate,
    'date'                        => Time.now.utc.httpdate,
    'server'                      => 'Hyperion 2.5',
    'access-control-allow-origin' => '*',
    'cross-origin-opener-policy'  => 'same-origin',
    'cross-origin-resource-policy' => 'same-origin'
  }
end

run ->(env) { [200, headers_for(env), [BODY]] }
