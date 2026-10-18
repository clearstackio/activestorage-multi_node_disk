# frozen_string_literal: true

require "rails_helper"

# A file on another node: every other node is asked at once; the first copy
# that matches the blob wins.
RSpec.describe ActiveStorage::Service::MultiNodeDiskService, "discovery" do
  let(:blob) { document_with_file.file.blob }
  let(:node_b) { multi_node_disk_node("node-b") }
  let(:node_c) { multi_node_disk_node("node-c") }
  let(:events) { [] }

  around do |example|
    subscriber = ActiveSupport::Notifications.subscribe(/multi_node_disk\z/) { |*args| events << ActiveSupport::Notifications::Event.new(*args) }
    example.run
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  def outcomes = events.find { |event| event.name == "fetch.multi_node_disk" }.payload[:outcomes]

  it "reads a local file without asking anyone" do
    multi_node_disk_cluster("node-b" => node_b, "node-c" => node_c) do |requests|
      expect(blob.download).to eq(Documents::BYTES)
      expect(requests).to be_empty
    end
  end

  it "takes the file from the second node" do
    multi_node_disk_move(blob, to: node_b)

    multi_node_disk_cluster("node-b" => node_b, "node-c" => :missing) do |requests|
      expect(blob.download).to eq(Documents::BYTES)
      to_b = requests.find { |entry| entry[:node] == "node-b" }
      expect(to_b[:headers]).to include("X-Multi-Node-Disk-Hop")
      expect(to_b[:url]).to eq("https://node-b/rails/active_storage/multi_node_disk/blobs/#{blob.key}")
    end
  end

  it "takes the file from the third node when the second answers 404" do
    multi_node_disk_move(blob, to: node_c)

    multi_node_disk_cluster("node-b" => node_b, "node-c" => node_c) do
      expect(blob.download).to eq(Documents::BYTES)
      expect(outcomes["node-c"]).to eq(:hit)
      expect(outcomes["node-b"]).to be_in(%i[missing skipped])
    end
  end

  it "skips a copy that does not match the blob and reports it" do
    multi_node_disk_move(blob, to: node_c)

    multi_node_disk_cluster("node-b" => :wrong, "node-c" => node_c) do
      expect(blob.download).to eq(Documents::BYTES)
    end
    expect(outcomes["node-b"]).to be_in(%i[mismatch skipped])
  end

  it "says Mismatch when the only copy found is wrong" do
    FileUtils.rm(ActiveStorage::Blob.service.path_for(blob.key))

    multi_node_disk_cluster("node-b" => :wrong, "node-c" => :missing) do
      expect { blob.download }.to raise_error(ActiveStorage::MultiNodeDisk::Mismatch, /node-b/)
    end
    expect(events.map(&:name)).to include("mismatch.multi_node_disk")
  end

  it "says NotHere when every node answers 404 as itself" do
    FileUtils.rm(ActiveStorage::Blob.service.path_for(blob.key))

    multi_node_disk_cluster("node-b" => :missing, "node-c" => :missing) do
      expect { blob.download }.to raise_error(ActiveStorage::MultiNodeDisk::NotHere, /members.csv is not on node-a, node-b, and node-c/)
    end
  end

  it "says Unavailable, naming them, when nodes fail and nobody has the file" do
    FileUtils.rm(ActiveStorage::Blob.service.path_for(blob.key))

    multi_node_disk_cluster("node-b" => :down, "node-c" => :missing) do
      expect { blob.download }.to raise_error(ActiveStorage::MultiNodeDisk::Unavailable, /node-b is not answering/)
    end
  end

  it "takes the answer from one node while another times out, within the deadline" do
    multi_node_disk_move(blob, to: node_c)

    ActiveStorage::MultiNodeDisk.with_config(open_timeout: 0.2, read_timeout: 0.3) do
      multi_node_disk_cluster("node-b" => :timeout, "node-c" => node_c) do
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        expect(blob.download).to eq(Documents::BYTES)
        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 2
      end
    end
  end

  it "gives up at the deadline when the only other nodes never answer" do
    FileUtils.rm(ActiveStorage::Blob.service.path_for(blob.key))

    ActiveStorage::MultiNodeDisk.with_config(open_timeout: 0.1, read_timeout: 0.1) do
      multi_node_disk_cluster("node-b" => :timeout, "node-c" => :timeout) do
        expect { blob.download }.to raise_error(ActiveStorage::MultiNodeDisk::Unavailable, /node-b and node-c/)
      end
    end
  end

  it "counts a 404 from a node other than the one addressed as failed (a proxy's fallback)" do
    FileUtils.rm(ActiveStorage::Blob.service.path_for(blob.key))
    elsewhere = ->(*) { ActiveStorage::MultiNodeDisk::Response.new(404, "", {"X-Multi-Node-Disk-Node" => "node-c"}) }
    client = ->(method, url, headers:, node:, **) { (node == "node-b") ? elsewhere.call : ActiveStorage::MultiNodeDisk::Response.new(404, "", {"X-Multi-Node-Disk-Node" => node}) }

    ActiveStorage::MultiNodeDisk.with_config(http_client: client) do
      expect { blob.download }.to raise_error(ActiveStorage::MultiNodeDisk::Unavailable, /node-b/)
    end
  end

  it "streams and chunks a file from another node" do
    multi_node_disk_move(blob, to: node_b)

    multi_node_disk_cluster("node-b" => node_b, "node-c" => :missing) do
      chunks = []
      blob.download { |chunk| chunks << chunk }
      expect(chunks.join).to eq(Documents::BYTES)
      expect(blob.download_chunk(3..6)).to eq("name")
      blob.open { |file| expect(File.binread(file.path)).to eq(Documents::BYTES) }
    end
  end

  it "answers exist? from the other nodes" do
    multi_node_disk_move(blob, to: node_b)
    service = ActiveStorage::Blob.service

    multi_node_disk_cluster("node-b" => node_b, "node-c" => :missing) { expect(service.exist?(blob.key)).to be(true) }
    FileUtils.rm(node_b.path_for(blob.key))
    multi_node_disk_cluster("node-b" => node_b, "node-c" => :missing) { expect(service.exist?(blob.key)).to be(false) }
    multi_node_disk_cluster("node-b" => :down, "node-c" => :missing) do
      expect { service.exist?(blob.key) }.to raise_error(ActiveStorage::MultiNodeDisk::Unavailable)
    end
  end

  it "asks nobody on a single-node list" do
    single = described_class.new(root: Rails.root.join("tmp/storage/node-a").to_s, node: "node-a", nodes: ["node-a"]).tap { |object| object.name = :local }
    FileUtils.rm(ActiveStorage::Blob.service.path_for(blob.key))

    multi_node_disk_cluster({}) do |requests|
      expect { single.download(blob.key) }.to raise_error(ActiveStorage::MultiNodeDisk::NotHere)
      expect(requests).to be_empty
    end
  end

  context "with :token" do
    it "sends token_for(node, blob, :read) as a Bearer token, and the token reaches no event" do
      multi_node_disk_move(blob, to: node_b)
      seen = []
      token_for = ->(node, found, action) { seen << [node, found, action] && "t-#{node}" }

      with_token("t-node-b", token_for: token_for) do
        multi_node_disk_cluster("node-b" => node_b, "node-c" => :missing) do |requests|
          expect(blob.download).to eq(Documents::BYTES)
          expect(requests.find { |entry| entry[:node] == "node-b" }[:headers]).to include("Authorization")
        end
      end
      expect(seen).to include(["node-b", blob, :read], ["node-c", blob, :read])
      expect(events.map(&:payload).to_s).not_to include("t-node")
    end

    it "does not ask a node it has no token for, and counts it as failed" do
      FileUtils.rm(ActiveStorage::Blob.service.path_for(blob.key))

      with_token("x", token_for: ->(node, *) { (node == "node-b") ? nil : "x" }) do
        multi_node_disk_cluster("node-b" => :missing, "node-c" => :missing) do |requests|
          expect { blob.download }.to raise_error(ActiveStorage::MultiNodeDisk::Unavailable, /node-b/)
          expect(requests.map { |entry| entry[:node] }).to eq(["node-c"])
        end
      end
    end
  end

  it "sends no Authorization header without :token" do
    multi_node_disk_move(blob, to: node_b)

    multi_node_disk_cluster("node-b" => node_b, "node-c" => :missing) do |requests|
      blob.download
      expect(requests.flat_map { |entry| entry[:headers] }).not_to include("Authorization")
    end
  end

  it "refuses an http URL before sending anything" do
    ActiveStorage::MultiNodeDisk.with_config(url_for: ->(node, key) { "http://#{node}/#{key}" }) do
      FileUtils.rm(ActiveStorage::Blob.service.path_for(blob.key))
      expect { blob.download }.to raise_error(ActiveStorage::MultiNodeDisk::ConfigurationError, /https/)
    end
  end

  it "keeps the database out of the threads" do
    multi_node_disk_move(blob, to: node_b)
    queries = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| queries << Thread.current }

    multi_node_disk_cluster("node-b" => node_b, "node-c" => :missing) { blob.download }
    ActiveSupport::Notifications.unsubscribe(subscriber)
    # The in-process endpoint (node-b) looks its blob up on the fan-out
    # thread; the service itself only on the caller's.
    expect(queries.count(Thread.current)).to be >= 1
  end
end
