# frozen_string_literal: true

# 2.12-B bench rackup — small-static-asset row served via
# Hyperion::Server.handle_static.
#
# Mirrors bench/hello_static.ru's pattern but for the 1 KB static-row
# of the 4-way bench: the asset bytes are read off disk ONCE at boot
# time and registered with handle_static; subsequent requests hit the
# direct-dispatch C-ext fast path (2.10-D + 2.10-F + PageCache 2.10-C)
# with no per-request file I/O, no Rack::Files allocation, and no
# Rack-env build.
#
# This is the "Hyperion peak" rackup for the small-static row of the
# 2.12-B 4-way comparison. The companion rackup `bench/static.ru`
# (Rack::Files) is the generic Rack-style row that keeps the Rack
# adapter in the hot path; both rackups serve the same bytes so the
# delta is *only* the dispatch shape.
#
# Setup:
#   ruby -e 'File.binwrite("/tmp/hyperion_bench_1k.bin", "x" * 1024)'
#   bundle exec bin/hyperion -p 9292 bench/static_handle_static.ru
#   wrk -t4 -c100 -d20s http://127.0.0.1:9292/hyperion_bench_1k.bin
#
# The preload path is the URL the asset was originally served from —
# `/hyperion_bench_1k.bin` (matches bench/static.ru's URL_PATH so the
# 4way harness can flip rackups without changing URL_PATH).

require 'hyperion'

# Local variables (NOT top-level constants) — rackups can be re-parsed
# under spec runners, and constant redefinition warnings would clutter
# rspec output.
asset_dir  = ENV.fetch('HYPERION_BENCH_ASSET_DIR', '/tmp')
asset_name = ENV.fetch('HYPERION_BENCH_ASSET_NAME', 'hyperion_bench_1k.bin')
asset_path = File.join(asset_dir, asset_name)

unless File.exist?(asset_path)
  raise "[static_handle_static.ru] missing asset #{asset_path} — " \
        "run: ruby -e 'File.binwrite(#{asset_path.inspect}, \"x\" * 1024)'"
end

# Preload the asset bytes ONCE at boot time. handle_static freezes
# the body, builds the HTTP/1.1 head + body buffer, and folds the
# pre-built response into the C-side PageCache so PageCache.serve_request
# can write it without crossing back into Ruby.
asset_bytes = File.binread(asset_path)

# Content type matches what Rack::Files would send for a `.bin` extension
# (application/octet-stream) so the comparison row is apples-to-apples
# with bench/static.ru.
Hyperion::Server.handle_static(
  :GET,
  "/#{asset_name}",
  asset_bytes,
  content_type: 'application/octet-stream'
)

# Fallback for any path NOT registered above — keeps the rackup
# returning a 200/404 cleanly during smoke-check, never raising.
run ->(_env) { [404, { 'content-type' => 'text/plain' }, ['no route']] }
