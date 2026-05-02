# frozen_string_literal: true

# 2.14-A bench rackup — hello-world via the C-accept-loop dynamic-block
# dispatch path.  `Server.handle(:GET, '/') { |env| ... }` registers a
# Rack-style block; when the C accept loop is engaged (it is, since
# every entry in the route table is `DynamicBlockEntry`), the loop
# does accept + recv + parse without holding the GVL, hands the
# request to the registered block under the GVL, and writes the
# response without the GVL.
#
# Compare against `bench/hello.ru`: same hello-world workload; the
# difference is that the legacy rackup does not register through
# `Server.handle`, so it flows through the regular `Connection#serve`
# path and the GVL is held end-to-end per request.
#
# The Rack lambda below is the FALLBACK for any path NOT registered
# via `Server.handle`. Hitting `/` engages the C-accept-loop dynamic
# dispatch.

require 'hyperion'

Hyperion::Server.handle(:GET, '/') do |_env|
  [200, { 'content-type' => 'text/plain' }, ['hello']]
end

run ->(_env) { [404, { 'content-type' => 'text/plain' }, ['no route']] }
