# frozen_string_literal: true

require "rails_helper"

RSpec.describe ActiveStorage::MultiNodeDisk::TestHelper do
  let(:blob) { document_with_file.file.blob }
  let(:node_b) { multi_node_disk_node("node-b") }

  it "answers through the real endpoint as the other node, and leaves the caller's Current alone" do
    multi_node_disk_move(blob, to: node_b)
    ActiveStorage::Current.url_options = {host: "caller.test"}

    multi_node_disk_cluster("node-b" => node_b, "node-c" => :missing) { expect(blob.download).to eq(Documents::BYTES) }
    expect(ActiveStorage::Current.url_options).to eq(host: "caller.test")
  end

  it "records method, node, URL and header names, never header values" do
    multi_node_disk_move(blob, to: node_b)

    with_token("secret-value") do
      multi_node_disk_cluster("node-b" => node_b, "node-c" => :missing) do |requests|
        blob.download
        expect(requests.first.keys).to eq(%i[method node url headers])
        expect(requests.to_s).not_to include("secret-value")
      end
    end
  end

  it "restores the configuration after the block" do
    client = ActiveStorage::MultiNodeDisk.config.http_client
    multi_node_disk_cluster({}) { expect(ActiveStorage::MultiNodeDisk.config.http_client).not_to eq(client) }
    expect(ActiveStorage::MultiNodeDisk.config.http_client).to eq(client)
  end
end

RSpec.describe ActiveStorage::MultiNodeDisk::TestHelper, "behind a public prefix" do
  let(:blob) { document_with_file.file.blob }
  let(:node_b) { multi_node_disk_node("node-b") }

  it "answers a URL with a prefix before the mount path" do
    multi_node_disk_move(blob, to: node_b)
    url_for = ->(node, key) { "https://app.test/app#{ActiveStorage::MultiNodeDisk.mount_path}/blobs/#{key}" }

    ActiveStorage::MultiNodeDisk.with_config(url_for: url_for) do
      multi_node_disk_cluster("node-b" => node_b, "node-c" => :missing) { expect(blob.download).to eq(Documents::BYTES) }
    end
  end
end
