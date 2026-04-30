# frozen_string_literal: true

# kTLS large-payload TLS bench. Serves a 1 MiB asset from /tmp via
# Rack::Files. Pairs with bench/static.ru for the unencrypted comparison
# but adds the TLS layer so kTLS_TX vs userspace SSL_write is measurable.
#
# Phase 9 (commit 5c00b15) wires kTLS_TX on Linux ≥ 4.13 + OpenSSL ≥ 3.0.
# The hello-payload TLS bench did NOT show the kTLS win — at 5-byte
# response bodies the cipher cost is a tiny fraction of per-request
# overhead (parser + dispatch + handshake CPU dominate). The win
# compounds with LARGE payloads where SSL_write would otherwise burn
# userspace cycles encrypting MBs of data; this rackup exercises that
# path.
#
# Setup:
#   ruby -e 'File.binwrite("/tmp/hyperion_bench_1m.bin", "x" * (1024*1024))'
#   bundle exec hyperion --tls-cert /tmp/cert.pem --tls-key /tmp/key.pem \
#     -t 64 -w 1 -p 9601 bench/tls_static_1m.ru
#   wrk -t4 -c64 -d20s --latency --timeout 8s \
#     https://127.0.0.1:9601/hyperion_bench_1m.bin
#
# A/B kTLS via the env var (2.2.x fix-C):
#   HYPERION_TLS_KTLS=off bundle exec hyperion ...   # userspace SSL_write
#   HYPERION_TLS_KTLS=auto bundle exec hyperion ...  # kernel TLS_TX (default)
require 'rack/files'

ASSET_DIR = ENV.fetch('HYPERION_BENCH_ASSET_DIR', '/tmp')
run Rack::Files.new(ASSET_DIR)
