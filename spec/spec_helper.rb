# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'tempfile'
require 'hyperion'

Dir[File.expand_path('support/**/*.rb', __dir__)].each { |f| require f }

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
  config.order = :random

  # 1.8.0: the broad spec suite intentionally exercises deprecated DSL keys
  # (`h2_max_concurrent_streams`, `admin_token`, `Hyperion.metrics =`, …)
  # because those are still the canonical 1.x test seams. Keep the suite
  # quiet by default; specs that DO want to assert on the warn behaviour
  # (`deprecation_warns_spec.rb`) flip the silence off explicitly.
  config.before(:suite) { Hyperion::Deprecations.silence! }
end
