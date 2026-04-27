# frozen_string_literal: true

# Headers-heavy hello world. Adapter-side perf bench for the
# upcase_underscore C extension: every request the harness sends carries
# eight uncached X-Custom-* headers, so the
# `HTTP_KEY_CACHE[name] || upcase_underscore(name)` call fires eight times
# per request. Hello-world rackup with no DB / app work isolates the
# adapter cost from app-side noise.

EIGHT_RESPONSE_HEADERS = {
  'content-type' => 'text/plain',
  'x-custom-1' => 'a',
  'x-custom-2' => 'b',
  'x-custom-3' => 'c',
  'x-custom-4' => 'd',
  'x-custom-5' => 'e',
  'x-custom-6' => 'f',
  'x-custom-7' => 'g',
  'x-custom-8' => 'h'
}.freeze

run ->(_env) { [200, EIGHT_RESPONSE_HEADERS, ['ok']] }
