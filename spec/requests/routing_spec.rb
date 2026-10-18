# frozen_string_literal: true

require "rails_helper"

# The endpoint lives under Active Storage's prefix, apart from the app's routes.
RSpec.describe "Routing", type: :request do
  let(:app_routes) { Rails.application.routes.routes.map { |entry| entry.path.spec.to_s } }

  it "mounts the engine under Active Storage's prefix, ahead of the app's catch-all" do
    expect(app_routes).to include("/rails/active_storage/multi_node_disk")
    expect(app_routes.index("/rails/active_storage/multi_node_disk")).to be < app_routes.index("/*path(.:format)")
  end

  it "draws nothing at the app's root, and leaves the app's root and catch-all alone" do
    engine_paths = ActiveStorage::MultiNodeDisk::Engine.routes.routes.map { |entry| entry.path.spec.to_s }
    expect(engine_paths).to contain_exactly("/blobs/:key", "/blobs/:key")

    get "/"
    expect(response.body).to eq("host")
    get "/anything/else"
    expect(response.body).to eq("host")
    get "/rails/active_storage/multi_node_disk"
    expect(response.body).to eq("host")
  end

  it "keeps its route helpers in its own namespace" do
    expect(ActiveStorage::MultiNodeDisk::Engine.routes.url_helpers).to respond_to(:blob_path)
    expect(Rails.application.routes.url_helpers).not_to respond_to(:blob_path)
    expect(ActiveStorage::MultiNodeDisk::Engine.routes.url_helpers.blob_path("abc")).to eq("/rails/active_storage/multi_node_disk/blobs/abc")
  end

  it "draws nothing when draw_routes is false" do
    ActiveStorage::MultiNodeDisk.with_config(draw_routes: false) do
      Rails.application.reload_routes!
      expect(Rails.application.routes.routes.map { |entry| entry.path.spec.to_s }).not_to include("/rails/active_storage/multi_node_disk")
    end
  ensure
    Rails.application.reload_routes!
  end
end
