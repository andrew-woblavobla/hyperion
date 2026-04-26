# frozen_string_literal: true

# Static-asset benchmark: serve a 1 MiB file via Rack::Files. Demonstrates
# Hyperion's sendfile(2) zero-copy path (1.2.0+) vs Puma's userspace
# String-allocation path. To run:
#
#   ruby -e 'File.binwrite("/tmp/hyperion_bench_1m.bin", "x" * (1024*1024))'
#   bundle exec bin/hyperion -p 9292 bench/static.ru
#   wrk -t4 -c100 -d15s http://127.0.0.1:9292/asset.bin
require 'rack/files'

ASSET_DIR = ENV.fetch('HYPERION_BENCH_ASSET_DIR', '/tmp')

run Rack::Files.new(ASSET_DIR)
