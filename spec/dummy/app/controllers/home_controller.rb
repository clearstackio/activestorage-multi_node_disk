# frozen_string_literal: true

# The host's own pages: a root and a catch-all, to show the gem's routes
# neither hide nor are hidden by them.
class HomeController < ActionController::API
  def show
    render plain: "host"
  end
end
