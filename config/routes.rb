# frozen_string_literal: true

# The engine's own routes, under its mount path (Engine). GET also answers
# HEAD. Nothing at the engine's root.
ActiveStorage::MultiNodeDisk::Engine.routes.draw do
  scope format: false, constraints: {key: %r{[^/]+}} do
    get "blobs/:key" => "blobs#show", :as => :blob
    delete "blobs/:key" => "blobs#destroy"
  end
end
