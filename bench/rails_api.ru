# frozen_string_literal: true

# API-only Rails bench row. Hits /api/users — UsersController#index
# returns a static ~200-byte JSON without touching AR. Full Rails
# middleware stack + ActionController dispatch are exercised; only
# Action View and ActiveRecord are bypassed.
#
# The harness wrk URL is /api/users — see bench/run_all.sh.
ENV['RAILS_ENV']  ||= 'production'
ENV['RAILS_LOG_TO_STDOUT'] = nil  # logger goes to /dev/null per env config
ENV['RAILS_SERVE_STATIC_FILES'] = nil

require_relative 'rails_app/config/environment'

run Rails.application
