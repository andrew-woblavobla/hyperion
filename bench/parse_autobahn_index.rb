#!/usr/bin/env ruby
# frozen_string_literal: true

# Reads `autobahn-reports/index.json` (autobahn-testsuite fuzzingclient
# output) and prints a per-RFC-6455-section pass/fail breakdown.
#
# Usage:
#
#   ruby bench/parse_autobahn_index.rb autobahn-reports/index.json
#
# Behavior values per autobahn convention:
#
#   OK            — case passed strictly
#   NON-STRICT    — case passed but not at the earliest possible point
#                   (e.g. UTF-8 fail-fast position). Counts as a pass.
#   INFORMATIONAL — case is advisory only; outcome is recorded but the
#                   spec doesn't require either behaviour. Counts as a pass.
#   FAILED        — hard violation. The body should treat any non-zero
#                   FAILED count as a regression vs the published baseline
#                   in `docs/WEBSOCKETS.md`.
#   UNIMPLEMENTED — the server didn't react to the case at all. Usually
#                   indicates a missing feature (e.g. permessage-deflate
#                   not negotiated → all of sections 12/13 UNIMPLEMENTED).
#
# This is the same parser used to write up the 2.4-D autobahn run; it
# reads the autobahn report shape verbatim and does no normalisation
# beyond grouping cases by their leading section number.

require 'json'

path = ARGV[0] or abort 'usage: parse_autobahn_index.rb <index.json>'
raw = JSON.parse(File.read(path))
agent = raw.keys.first
cases = raw[agent]

sections = Hash.new { |h, k| h[k] = Hash.new(0) }
cases.each do |id, info|
  section = id.split('.').first
  behavior = info['behavior']
  sections[section][behavior] += 1
  sections[section][:total] += 1
end

ok_total = 0
total_total = 0
sections.keys.sort_by { |k| k.to_i }.each do |sec|
  s = sections[sec]
  ok = s['OK'].to_i + s['INFORMATIONAL'].to_i + s['NON-STRICT'].to_i
  fail_count = s['FAILED'].to_i
  unimp = s['UNIMPLEMENTED'].to_i
  total = s[:total]
  pct = total.positive? ? (ok * 100.0 / total) : 0.0
  ok_total += ok
  total_total += total
  puts format('Section %2s: %3d/%3d  OK=%-3d INFO=%-3d NON-STRICT=%-3d FAILED=%-3d UNIMP=%-3d (%.1f%%)',
              sec, ok, total,
              s['OK'].to_i, s['INFORMATIONAL'].to_i, s['NON-STRICT'].to_i,
              fail_count, unimp, pct)
end
puts '-' * 72
puts format('TOTAL    : %3d/%3d  (%.1f%%)', ok_total, total_total,
            ok_total * 100.0 / total_total)

failed_cases = cases.select { |_, v| v['behavior'] == 'FAILED' }
return if failed_cases.empty?

puts
puts 'FAILED cases:'
failed_cases.each do |id, v|
  puts "  #{id}  (close=#{v['behaviorClose']}, remoteCloseCode=#{v['remoteCloseCode']})"
end
