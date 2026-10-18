# frozen_string_literal: true

require "rails_helper"

RSpec.describe ActiveStorage::MultiNodeDisk::NetHttpClient do
  subject(:client) { described_class.new }

  it "sends the method and headers over HTTPS and returns the status, body and headers" do
    stub = stub_request(:get, "https://node-b/rails/active_storage/multi_node_disk/blobs/k")
      .with(headers: {"Authorization" => "Bearer t", "X-Multi-Node-Disk-Hop" => "1"})
      .to_return(status: 200, body: "bytes", headers: {"X-Multi-Node-Disk-Node" => "node-b"})

    answer = client.call(:get, "https://node-b/rails/active_storage/multi_node_disk/blobs/k",
      headers: {"Authorization" => "Bearer t", "X-Multi-Node-Disk-Hop" => "1"}, node: "node-b", open_timeout: 3, read_timeout: 20)

    expect(stub).to have_been_requested
    expect(answer).to have_attributes(status: 200, body: "bytes")
    expect(answer.header("x-multi-node-disk-node")).to eq("node-b")
  end

  it "sends HEAD and DELETE" do
    stub_request(:head, "https://node-b/x").to_return(status: 200)
    stub_request(:delete, "https://node-b/x").to_return(status: 204)

    expect(client.call(:head, "https://node-b/x", headers: {}, node: "node-b", open_timeout: 1, read_timeout: 1).status).to eq(200)
    expect(client.call(:delete, "https://node-b/x", headers: {}, node: "node-b", open_timeout: 1, read_timeout: 1).status).to eq(204)
  end

  it "raises on a timeout, which the service counts as a failed node" do
    stub_request(:get, "https://node-b/x").to_timeout
    expect { client.call(:get, "https://node-b/x", headers: {}, node: "node-b", open_timeout: 1, read_timeout: 1) }.to raise_error(StandardError)
  end
end
