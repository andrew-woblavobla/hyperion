# frozen_string_literal: true

# Full-stack ERB Rails bench row. Hits /page — PagesController#show
# renders a layout + partial collection. Exercises Action View hot
# path (ERB compile is one-time, render is per-request). No AR.
#
# The harness wrk URL is /page — see bench/run_all.sh.
ENV['RAILS_ENV']  ||= 'production'

require_relative 'rails_app/config/environment'

run Rails.application
