# frozen_string_literal: true

require "rails_helper"

RSpec.describe ActiveStorage::MultiNodeDisk do
  it "is 0.1.0" do
    expect(ActiveStorage::MultiNodeDisk::VERSION).to eq("0.1.0")
  end

  it "builds the storage.yml service through Active Storage's Configurator" do
    expect(ActiveStorage::Blob.service).to be_a(ActiveStorage::Service::MultiNodeDiskService)
    expect(ActiveStorage::Blob.service).to have_attributes(name: :local, node: "node-a", nodes: %w[node-a node-b node-c])
  end
end
