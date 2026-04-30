# frozen_string_literal: true

# kTLS mid-payload TLS bench. Generates a ~50 KB JSON response per
# request. Sized to fall in the kTLS_TX sweet spot — large enough that
# cipher cost is meaningful, small enough to stay below the kernel TCP
# send buffer in one syscall (default `net.ipv4.tcp_wmem` max ~6 MB on
# Linux).
#
# Phase 9 (commit 5c00b15) wires kTLS_TX on Linux ≥ 4.13 + OpenSSL ≥ 3.0.
# At hello-payload (5 B body) the cipher cost is a tiny fraction of the
# per-request budget; the kTLS win surfaces only when the payload is
# big enough that SSL_write would burn userspace cycles encrypting it.
# 50 KB is the workload where the cipher cost / per-request-overhead
# ratio tips in kTLS_TX's favour.
#
# Setup:
#   bundle exec hyperion --tls-cert /tmp/cert.pem --tls-key /tmp/key.pem \
#     -t 64 -w 1 -p 9601 bench/tls_json_50k.ru
#   wrk -t4 -c64 -d20s --latency --timeout 8s https://127.0.0.1:9601/
#
# A/B kTLS via the env var (2.2.x fix-C):
#   HYPERION_TLS_KTLS=off bundle exec hyperion ...   # userspace SSL_write
#   HYPERION_TLS_KTLS=auto bundle exec hyperion ...  # kernel TLS_TX (default)
require 'json'

# 600 items × 8× name multiplier lands at ~50 KB (verified 50,039 bytes
# on ruby 3.3.3). If you tweak these numbers, target 40-60 KB — outside
# that range the kTLS sweet spot starts to shift.
#
# Wrapped in a module + `defined?`-guarded so re-`require`ing the rackup
# (e.g. specs that parse it twice) doesn't trigger "already initialized
# constant" warns.
module HyperionBenchTlsJson50k
  unless defined?(PAYLOAD)
    PAYLOAD = JSON.generate(
      { items: (1..600).map { |i| { id: i, name: "item-#{i}" * 8 } } }
    ).freeze
    HEADERS = { 'content-type' => 'application/json' }.freeze
  end
end

run lambda { |_env|
  [200, HyperionBenchTlsJson50k::HEADERS, [HyperionBenchTlsJson50k::PAYLOAD]]
}
