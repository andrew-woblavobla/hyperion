# frozen_string_literal: true

# 2.5-D — light wrapper around bench/ws_compression_bomb_fuzz.rb. The
# fuzz harness boots a Connection on each side of a UNIXSocket pair
# and throws six adversarial input vectors at it (see the bench file's
# header comment). This spec is the regression-guard form: a single
# example tagged `:perf` that calls into Run.call and asserts every
# vector returned `:passed => true`.
#
# Skipped by default rspec; operators run via:
#
#   bundle exec rspec --tag perf spec/hyperion/websocket_compression_bomb_fuzz_spec.rb
#
# or the env-var equivalent:
#
#   HYPERION_RUN_PERF_SPECS=1 bundle exec rspec spec/hyperion/websocket_compression_bomb_fuzz_spec.rb
#
# Total runtime budget: ≤ 5 minutes (the 4 GB ratio bomb is the
# slowest — bounded to ≤ 2 minutes by RATIO_BOMB_TIMEOUT in the
# bench script).

require 'spec_helper'
require_relative '../../bench/ws_compression_bomb_fuzz'

RSpec.describe '2.5-D permessage-deflate compression-bomb fuzz harness', :perf do
  it 'survives all 6 adversarial input vectors with the expected close codes and bounded RSS' do
    results = Hyperion::Bench::WsCompressionBombFuzz::Run.call

    expect(results.size).to eq(6)
    failed = results.reject { |r| r[:passed] }
    crashed = results.select { |r| r[:crashed] }

    expect(crashed).to be_empty, lambda {
      crashed.map { |r| "#{r[:name]}: #{r[:crash_message]}" }.join("\n")
    }
    expect(failed).to be_empty, lambda {
      failed.map { |r| "#{r[:name]} FAILED: close_code=#{r[:close_code]} rss_delta=#{r[:rss_delta_bytes]}" }.join("\n")
    }

    # Surface the per-vector PASS/FAIL summary in the spec output too.
    results.each do |r|
      expect(r[:passed]).to(be(true), "vector #{r[:name]} did not pass: #{r.inspect}")
    end
  end
end
