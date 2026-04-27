# frozen_string_literal: true

# Same as headers_heavy.ru but force the Ruby fallback for upcase_underscore
# so we can A/B test the C path against the pure-Ruby path on the same
# rackup harness (everything else identical).
require 'hyperion/adapter/rack'
Hyperion::Adapter::Rack.instance_variable_set(:@c_upcase_available, false)

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
