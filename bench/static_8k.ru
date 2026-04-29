# frozen_string_literal: true

# Static-asset benchmark — small file (8 KB) sanity check.
#
# Mirrors bench/static.ru but pointed at /tmp/hyperion_bench_8k.bin.
# Phase 1 sendfile path is biased toward larger files; this row guards
# the small-file case from regressing as we tune sendfile thresholds.
#
# Setup:
#   ruby -e 'File.binwrite("/tmp/hyperion_bench_8k.bin", "x" * 8192)'
#   bundle exec bin/hyperion -p 9292 bench/static_8k.ru
#   wrk -t4 -c100 -d20s http://127.0.0.1:9292/hyperion_bench_8k.bin
require 'rack/files'

ASSET_DIR = ENV.fetch('HYPERION_BENCH_ASSET_DIR', '/tmp')

run Rack::Files.new(ASSET_DIR)
