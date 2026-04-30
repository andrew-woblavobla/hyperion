# frozen_string_literal: true

# Tiny POST handler for HPACK benchmarking. Returns 201 with a
# medium-realistic response header set so the encoder exercises both
# static-table-matched (`:status 200`/`:status 204` adjacent slots,
# `content-type`, `content-length`) and literal-with-incremental-
# indexing (`x-request-id`, `x-trace-id`) paths.
#
# Run with:
#   bundle exec hyperion --workers 1 -t 0 \
#     --tls-cert tls.crt --tls-key tls.key \
#     --h2-max-total-streams unbounded bench/h2_post.ru
#
# Then drive load with h2load:
#   h2load -c 1 -m 100 -n 5000 -d /dev/zero https://127.0.0.1:9292/echo
#
# Note (2.2.x fix-D): h2load -n 5000 opens 5,000 streams on a single
# connection, which exceeds the 2.0.0 default cap of
# `max_concurrent_streams × workers × 4` (= 512 on -w 1). Without
# `--h2-max-total-streams unbounded` (or a numeric value ≥ 5000) the
# connection is closed mid-test and h2load reports thousands of errored
# streams. The HYPERION_H2_MAX_TOTAL_STREAMS env-var is equivalent —
# useful when scripted bench sweeps prefer env over flags.

run lambda { |env|
  request_id = (env['HTTP_X_REQUEST_ID'] || '01HZ8N9Q3J5K6M7P8R9S0T1V2W')
  body = +'{"ok":true}'
  [
    201,
    {
      'content-type'   => 'application/json',
      'content-length' => body.bytesize.to_s,
      'cache-control'  => 'no-store',
      'x-request-id'   => request_id,
      'x-trace-id'     => '7f9d4a2e-' + request_id[-12..],
      'vary'           => 'Accept-Encoding',
      'server'         => 'hyperion'
    },
    [body]
  ]
}
