# frozen_string_literal: true

Rails.application.routes.draw do
  root "home#show"
  get "documents/:id" => "home#show", :as => :document
  get "*path" => "home#show"
end
