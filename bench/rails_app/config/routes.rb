# frozen_string_literal: true

Rails.application.routes.draw do
  # Bench rows hit these URLs:
  get '/api/users',  to: 'users#index'    # API-only row
  get '/users.json', to: 'users#index_db' # AR-CRUD row
  get '/page',       to: 'pages#show'     # ERB row

  # Warmup hit fired once after bind (drives YJIT to compile hot path
  # before wrk starts). Ultra-cheap — no controller, no routing layer.
  get '/healthz', to: ->(_env) { [200, { 'content-type' => 'text/plain' }, ['ok']] }
end
