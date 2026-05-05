# frozen_string_literal: true

class UsersController < ApplicationController
  # Static JSON, no AR — the API-only bench row hits this.
  STATIC_JSON = {
    status: 'ok',
    user: { id: 42, name: 'Alice', email: 'alice@example.com' },
    meta: { version: '1.0', region: 'bench' }
  }.to_json.freeze

  def index
    render json: STATIC_JSON
  end

  # AR-backed JSON — the AR-CRUD bench row hits this.
  def index_db
    render json: User.limit(10).as_json(only: %i[id name email])
  end
end
