# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Hyperion::PrometheusExporter do
  describe '.render' do
    it 'returns an empty string when given empty stats' do
      expect(described_class.render({})).to eq('')
    end

    it 'renders a known counter with curated HELP and TYPE lines' do
      out = described_class.render(requests: 100)

      expect(out).to include("# HELP hyperion_requests_total Total HTTP requests handled\n")
      expect(out).to include("# TYPE hyperion_requests_total counter\n")
      expect(out).to include("hyperion_requests_total 100\n")
    end

    it 'groups status counters under a single labeled family' do
      out = described_class.render(responses_200: 50, responses_404: 5, responses_500: 1)

      # Single HELP/TYPE pair for the whole family
      expect(out.scan('# HELP hyperion_responses_status_total').size).to eq(1)
      expect(out.scan('# TYPE hyperion_responses_status_total').size).to eq(1)
      expect(out).to include(%(hyperion_responses_status_total{status="200"} 50\n))
      expect(out).to include(%(hyperion_responses_status_total{status="404"} 5\n))
      expect(out).to include(%(hyperion_responses_status_total{status="500"} 1\n))
    end

    it 'sorts status codes ascending in the output' do
      out = described_class.render(responses_500: 1, responses_200: 50, responses_404: 5)

      idx_200 = out.index('status="200"')
      idx_404 = out.index('status="404"')
      idx_500 = out.index('status="500"')
      expect(idx_200).to be < idx_404
      expect(idx_404).to be < idx_500
    end

    it 'auto-exports unknown counters with a generic HELP line' do
      out = described_class.render(custom_thing: 7)

      expect(out).to include("# HELP hyperion_custom_thing Hyperion internal counter (auto-exported)\n")
      expect(out).to include("# TYPE hyperion_custom_thing counter\n")
      expect(out).to include("hyperion_custom_thing 7\n")
    end

    it 'renders a full snapshot with known + status + unknown keys together' do
      stats = {
        requests: 10,
        bytes_written: 2048,
        responses_200: 9,
        responses_500: 1,
        custom_thing: 3
      }
      out = described_class.render(stats)

      # Known metrics rendered in declaration order, before status family
      idx_requests = out.index('hyperion_requests_total 10')
      idx_bytes    = out.index('hyperion_bytes_written_total 2048')
      idx_status   = out.index('hyperion_responses_status_total{status="200"}')
      idx_custom   = out.index('hyperion_custom_thing 3')

      expect([idx_requests, idx_bytes, idx_status, idx_custom]).to all(be_a(Integer))
      expect(idx_requests).to be < idx_bytes
      expect(idx_bytes).to be < idx_status
      expect(idx_status).to be < idx_custom
    end
  end
end
