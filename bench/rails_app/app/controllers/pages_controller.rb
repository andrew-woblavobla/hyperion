# frozen_string_literal: true

class PagesController < ApplicationController
  # ERB layout + partial render — the ERB bench row hits this.
  # No AR; isolates Action View / template rendering hot path.
  def show
    @title    = 'Hyperion bench'
    @subtitle = 'ERB render row'
    @items    = (1..10).map { |i| { id: i, label: "item-#{i}" } }
    # Default render: app/views/pages/show.html.erb
  end
end
