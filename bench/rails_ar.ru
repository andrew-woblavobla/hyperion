# frozen_string_literal: true

# AR-CRUD Rails bench row. Hits /users.json — UsersController#index_db
# runs `User.limit(10).as_json` against a shared in-memory SQLite
# (mode=memory&cache=shared in config/database.yml). 100 rows seeded
# at boot via config.after_initialize.
#
# The harness wrk URL is /users.json — see bench/run_all.sh.
ENV['RAILS_ENV']  ||= 'production'

require_relative 'rails_app/config/environment'

# Force the seed hook to run + the AR connection pool to warm up
# before the first wrk request. Without this, the very first request
# under each worker pays the migration + seed cost.
User.count

run Rails.application
