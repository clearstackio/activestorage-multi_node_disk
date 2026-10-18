# frozen_string_literal: true

require "rails_helper"

# Delete: this disk, then every other node, inline (:sync) or through
# DeleteJob (:job).
RSpec.describe ActiveStorage::Service::MultiNodeDiskService, "delete" do
  let(:document) { document_with_file }
  let(:blob) { document.file.blob }
  let(:service) { ActiveStorage::Blob.service }
  let(:node_b) { multi_node_disk_node("node-b") }

  context "with :sync (the default)" do
    it "deletes here and on every other node; a 404 as itself counts as done" do
      multi_node_disk_cluster("node-b" => node_b, "node-c" => :missing) do |requests|
        service.delete(blob.key)

        expect(File.exist?(service.path_for(blob.key))).to be(false)
        expect(requests.map { |entry| [entry[:method], entry[:node]] }).to contain_exactly([:delete, "node-b"], [:delete, "node-c"])
      end
    end

    it "deletes the copy on the node that holds it" do
      multi_node_disk_move(blob, to: node_b)

      multi_node_disk_cluster("node-b" => node_b, "node-c" => :missing) { service.delete(blob.key) }
      expect(File.exist?(node_b.path_for(blob.key))).to be(false)
    end

    it "raises Unavailable naming the node that did not confirm, after trying every node" do
      multi_node_disk_cluster("node-b" => :down, "node-c" => :missing) do |requests|
        expect { service.delete(blob.key) }.to raise_error(ActiveStorage::MultiNodeDisk::Unavailable, /node-b is not answering: delete not confirmed/)
        expect(requests.size).to eq(2)
      end
      expect(File.exist?(service.path_for(blob.key))).to be(false)
    end

    it "works through Rails' purge, rows first, and keeps Rails' rule for a blob still attached elsewhere" do
      other = Document.create!(title: "other").tap { |object| object.file.attach(blob) }

      multi_node_disk_cluster("node-b" => :missing, "node-c" => :missing) { document.file.purge }
      expect(other.reload.file.download).to eq(Documents::BYTES)

      multi_node_disk_cluster("node-b" => :missing, "node-c" => :missing) { other.file.purge }
      expect(ActiveStorage::Blob.exists?(blob.id)).to be(false)
    end

    it "cleans up a failed upload on this node only" do
      multi_node_disk_cluster("node-b" => :down, "node-c" => :down) do |requests|
        expect { service.upload("k-#{SecureRandom.hex}", StringIO.new("x"), checksum: "bad") }.to raise_error(ActiveStorage::IntegrityError)
        expect(requests).to be_empty
      end
    end
  end

  context "with :job" do
    around { |example| ActiveStorage::MultiNodeDisk.with_config(delete_mode: :job, delete_job_queue: :files) { example.run } }

    let(:job) { ActiveStorage::MultiNodeDisk::DeleteJob }

    it "deletes here at once and queues the other nodes' deletes" do
      multi_node_disk_cluster("node-b" => node_b) do |requests|
        expect { service.delete(blob.key) }.to have_enqueued_job(job).with("local", blob.key, %w[node-b node-c], nil).on_queue("files")
        expect(requests).to be_empty
      end
      expect(File.exist?(service.path_for(blob.key))).to be(false)
    end

    it "is idempotent: a 404 is done, and a second run changes nothing" do
      multi_node_disk_move(blob, to: node_b)

      multi_node_disk_cluster("node-b" => node_b, "node-c" => :missing) do |requests|
        2.times { job.perform_now("local", blob.key, %w[node-b node-c]) }
        expect(requests.size).to eq(4)
      end
      expect(File.exist?(node_b.path_for(blob.key))).to be(false)
      expect(job).not_to have_been_enqueued
    end

    it "retries while a node does not confirm, for that node" do
      multi_node_disk_cluster("node-b" => :down, "node-c" => :missing) do
        expect { job.perform_now("local", blob.key, %w[node-b node-c]) }.to have_enqueued_job(job).with("local", blob.key, %w[node-b node-c])
      end
    end

    it "takes a host subclass for other retries" do
      subclass = Class.new(job) { def self.name = "HostDeleteJob" }
      stub_const("HostDeleteJob", subclass)

      ActiveStorage::MultiNodeDisk.with_config(delete_job_class: "HostDeleteJob") do
        expect { service.delete(blob.key) }.to have_enqueued_job(subclass)
      end
    end
  end

  it "fails boot validation for :job without Active Job" do
    config = ActiveStorage::MultiNodeDisk::Configuration.new.tap { |object| object.delete_mode = :job }
    allow(config).to receive(:require).and_call_original
    allow(config).to receive(:require).with("active_job").and_raise(LoadError, "cannot load such file -- active_job")

    expect { config.validate! }.to raise_error(ActiveStorage::MultiNodeDisk::ConfigurationError, /needs Active Job/)
  end
end
