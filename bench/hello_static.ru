# frozen_string_literal: true

# 2.10-F bench rackup — hello-world via Hyperion::Server.handle_static.
# Routes registered at boot time so the request hot path is the
# direct-dispatch fast path (2.10-D) backed by the C-ext fast-path
# response writer (2.10-F).
#
# The Rack lambda below is the FALLBACK for any path NOT registered
# below — kept so the rackup still serves a 200 if wrk hits a
# different URL during smoke testing.

require 'hyperion'

Hyperion::Server.handle_static(:GET, '/', 'hello')

run ->(_env) { [404, { 'content-type' => 'text/plain' }, ['no route']] }
