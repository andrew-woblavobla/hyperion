# frozen_string_literal: true

require 'hyperion'
require 'hyperion/websocket/connection'

# 2.9-C — per-route permessage-deflate ratio histogram.
#
# 2.4-C shipped `hyperion_websocket_deflate_ratio` as a process-wide
# histogram. ActionCable / pubsub apps with multiple channels (chat,
# notifications, presence, telemetry — each with different payload
# shapes) want a per-channel breakdown: chat compresses 20× on JSON,
# binary-frame telemetry may compress 1.5×. The aggregate gauge buries
# this signal.
#
# 2.9-C adds a `route` label to the histogram. Resolution is one-shot
# at handshake time (Connection construction); the resolved label is
# cached in `@deflate_ratio_labels` so per-message observations stay
# allocation-free.
#
# This spec covers:
#   1. Two routes get separate histogram series
#   2. Aggregating `sum without (route)` recovers the prior process-
#      wide signal (no signal lost; just split)
#   3. The path templater dedupes high-cardinality dynamic segments
#      so `/notifications/123` and `/notifications/124` both land on
#      `/notifications/:id`
#   4. `env['hyperion.websocket.route']` wins over PATH_INFO templating
#   5. Each Connection resolves the route label exactly once
RSpec.describe 'Hyperion::WebSocket per-route deflate ratio (2.9-C)' do
  let(:permessage_deflate_extension) do
    {
      permessage_deflate: {
        server_no_context_takeover: false,
        client_no_context_takeover: false,
        server_max_window_bits: 15,
        client_max_window_bits: 15
      }
    }
  end

  # JSON-shape compressible payload — 1 KiB of repeating field/value
  # pairs that mirror chat traffic. Compresses ~ 20× under raw -15
  # window, comfortably above the 1.5× histogram floor.
  CHAT_PAYLOAD = %({"type":"message","body":"hello","user":"alice"} * 20)[0, 1024].b.freeze

  # Capture the active metrics sink at the start of each example so
  # observations don't leak across cases. Reset after.
  around do |example|
    Hyperion::Runtime.reset_default!
    Hyperion::Metrics.reset_default_path_templater!
    Hyperion.metrics.reset!
    example.run
  ensure
    Hyperion.metrics.reset!
    Hyperion::Runtime.reset_default!
    Hyperion::Metrics.reset_default_path_templater!
  end

  def build_ws(env: nil, route: nil)
    socket = double('socket', write: 1)
    Hyperion::WebSocket::Connection.new(
      socket,
      ping_interval: nil, idle_timeout: nil,
      extensions: permessage_deflate_extension,
      env: env, route: route
    )
  end

  def deflate_n_messages(ws, count, payload: CHAT_PAYLOAD)
    count.times { ws.__send__(:deflate_message, payload) }
  end

  def histogram_series
    snap = Hyperion.metrics.histogram_snapshot[
      Hyperion::WebSocket::Connection::DEFLATE_RATIO_HISTOGRAM
    ]
    snap.nil? ? {} : snap[:series]
  end

  it 'records separate histogram series for two distinct routes' do
    cable_ws = build_ws(env: { 'PATH_INFO' => '/cable' })
    notif_ws = build_ws(env: { 'PATH_INFO' => '/notifications/42' })

    deflate_n_messages(cable_ws, 100)
    deflate_n_messages(notif_ws, 100)

    series = histogram_series
    expect(series.keys).to contain_exactly(['/cable'], ['/notifications/:id'])
    expect(series[['/cable']][:count]).to eq(100)
    expect(series[['/notifications/:id']][:count]).to eq(100)
  end

  it 'preserves the process-wide aggregate when summing across routes' do
    cable_ws = build_ws(env: { 'PATH_INFO' => '/cable' })
    notif_ws = build_ws(env: { 'PATH_INFO' => '/notifications/42' })

    deflate_n_messages(cable_ws, 100)
    deflate_n_messages(notif_ws, 100)

    series = histogram_series
    aggregate_count = series.values.sum { |s| s[:count] }
    aggregate_sum   = series.values.sum { |s| s[:sum] }

    # 200 observations total — equivalent to the pre-2.9-C single-
    # series count.
    expect(aggregate_count).to eq(200)
    # The mean ratio across both routes is positive and finite —
    # `sum without (route)` recovers the prior signal in PromQL.
    expect(aggregate_sum).to be > 0.0
    expect(aggregate_sum / aggregate_count).to be > 1.0
  end

  it 'dedupes high-cardinality dynamic segments via the path templater' do
    # 50 distinct user-supplied notification IDs — operator who didn't
    # name their channel still ends up with one series, not 50.
    50.times do |i|
      ws = build_ws(env: { 'PATH_INFO' => "/notifications/#{100 + i}" })
      deflate_n_messages(ws, 1)
    end

    series = histogram_series
    expect(series.keys).to eq([['/notifications/:id']])
    expect(series[['/notifications/:id']][:count]).to eq(50)
  end

  it 'lets `env[hyperion.websocket.route]` override PATH_INFO templating' do
    # Operator names the channel explicitly — the explicit name beats
    # whatever `PATH_INFO` happens to be.
    ws = build_ws(
      env: {
        'hyperion.websocket.route' => 'chat',
        'PATH_INFO' => '/cable'
      }
    )
    deflate_n_messages(ws, 10)

    series = histogram_series
    expect(series.keys).to eq([['chat']])
    expect(series[['chat']][:count]).to eq(10)
  end

  it 'resolves the route label exactly once per Connection (no per-message leak)' do
    ws = build_ws(env: { 'PATH_INFO' => '/cable' })

    # Drive 100 deflate observations. The route_resolutions counter
    # is bumped once at construction; nothing on the per-message path
    # should touch it again.
    deflate_n_messages(ws, 100)

    expect(ws.route_resolutions).to eq(1)
  end

  it 'falls back to "unrouted" when neither env nor route is supplied' do
    socket = double('socket', write: 1)
    ws = Hyperion::WebSocket::Connection.new(
      socket,
      ping_interval: nil, idle_timeout: nil,
      extensions: permessage_deflate_extension
    )
    deflate_n_messages(ws, 5)

    series = histogram_series
    expect(series.keys).to eq([['unrouted']])
    expect(series[['unrouted']][:count]).to eq(5)
  end

  it 'honours an explicit route: kwarg even without an env' do
    ws = build_ws(route: 'presence')
    deflate_n_messages(ws, 7)

    series = histogram_series
    expect(series.keys).to eq([['presence']])
    expect(series[['presence']][:count]).to eq(7)
  end

  it 'caches the resolved labels tuple as a frozen Array (no per-msg alloc)' do
    ws = build_ws(env: { 'PATH_INFO' => '/cable' })

    labels = ws.instance_variable_get(:@deflate_ratio_labels)
    expect(labels).to eq(['/cable'])
    expect(labels).to be_frozen
    expect(labels.first).to be_frozen

    # Drive a second observation; the labels Array ref must not change.
    deflate_n_messages(ws, 2)
    expect(ws.instance_variable_get(:@deflate_ratio_labels)).to equal(labels)
  end
end
