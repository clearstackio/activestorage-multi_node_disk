# frozen_string_literal: true

require "rails_helper"

# A file on this node: everything is Disk's, and no other node is asked.
RSpec.describe ActiveStorage::Service::MultiNodeDiskService do
  let(:service) { ActiveStorage::Blob.service }
  let(:document) { document_with_file }
  let(:blob) { document.file.blob }

  around { |example|
    multi_node_disk_cluster({}) { |requests|
      @requests = requests
      example.run
    }
  }

  it "uploads to this node's disk, as Disk" do
    expect(File.binread(service.path_for(blob.key))).to eq(Documents::BYTES)
  end

  it "reads, streams, chunks, opens and finds a local file without asking another node" do
    expect(blob.download).to eq(Documents::BYTES)
    expect(enum_for(:download_stream, blob).to_a.join).to eq(Documents::BYTES)
    expect(blob.download_chunk(0..1)).to eq("id")
    blob.open { |file| expect(File.binread(file.path)).to eq(Documents::BYTES) }
    expect(service.exist?(blob.key)).to be(true)
    expect(@requests).to be_empty
  end

  it "names the tempfile with the blob's extension, as Rails does" do
    blob.open { |file| expect(File.extname(file.path)).to eq(".csv") }
  end

  it "refuses a whole-file download whose local bytes do not match the blob" do
    File.binwrite(service.path_for(blob.key), "tampered")
    expect { blob.download }.to raise_error(ActiveStorage::MultiNodeDisk::Mismatch, /members.csv: the bytes do not match/)
  end

  it "raises Mismatch from open for corrupted local bytes, and leaves the block's own errors alone" do
    File.binwrite(service.path_for(blob.key), "tampered")
    expect { blob.open { flunk } }.to raise_error(ActiveStorage::IntegrityError, /members.csv/)

    File.binwrite(service.path_for(blob.key), Documents::BYTES)
    expect { blob.open { raise ArgumentError, "mine" } }.to raise_error(ArgumentError, "mine")
  end

  it "maps its errors through config.error_mapper" do
    host_error = Class.new(ActiveStorage::MultiNodeDisk::Mismatch)
    File.binwrite(service.path_for(blob.key), "tampered")

    ActiveStorage::MultiNodeDisk.with_config(error_mapper: ->(error) { host_error.new(nodes: error.nodes, key: error.key) }) do
      expect { blob.download }.to raise_error(host_error)
    end
  end

  it "deletes a file that fails its upload checksum on this node only" do
    expect {
      service.upload("upload-key", StringIO.new("abc"), checksum: "wrong")
    }.to raise_error(ActiveStorage::IntegrityError)
    expect(File.exist?(service.path_for("upload-key"))).to be(false)
    expect(@requests).to be_empty
  end

  it "keeps a key with no blob row (a variant) local, as Disk" do
    expect { service.download("variants/none/digest") }.to raise_error(ActiveStorage::FileNotFoundError)
    expect(service.exist?("variants/none/digest")).to be(false)
    expect(@requests).to be_empty
  end

  it "takes node:, nodes:, timeouts and auth from storage.yml over the configuration" do
    built = described_class.new(root: "/tmp/x", node: "n1", nodes: %w[n1 n2], open_timeout: 1, read_timeout: 2, auth: [:ip, :token], allowed_ips: ["10.0.0.0/8"])

    expect(built).to have_attributes(node: "n1", nodes: %w[n1 n2], auth_modes: %i[ip token])
    expect(built.send(:open_timeout)).to eq(1)
    expect(built.allowed_ips.first).to include(IPAddr.new("10.1.2.3"))
  end

  it "needs a node list" do
    expect { described_class.new(root: "/tmp/x").nodes }.to raise_error(ActiveStorage::MultiNodeDisk::ConfigurationError, /nodes/)
  end

  def download_stream(blob, &) = blob.download(&)
end
