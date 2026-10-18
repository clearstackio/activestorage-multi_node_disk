# frozen_string_literal: true

require "rails_helper"

RSpec.describe ActiveStorage::MultiNodeDisk::AuditLog do
  let(:blob) { document_with_file.file.blob }
  let(:node_b) { multi_node_disk_node("node-b") }
  let(:path) { Rails.root.join("tmp/audit-#{SecureRandom.hex(4)}.log") }
  let(:entries) { File.readlines(path).map { |line| JSON.parse(line) } }

  after { FileUtils.rm_f(path) }

  def endpoint_path = "/rails/active_storage/multi_node_disk/blobs/#{blob.key}"

  describe "the :file sink (default)" do
    around { |example| ActiveStorage::MultiNodeDisk.with_config(audit_path: path) { example.run } }

    it "writes one versioned JSON line per answered request, without the token" do
      with_token("audit-secret") do
        Rails.application.call(Rack::MockRequest.env_for(endpoint_path, "HTTP_AUTHORIZATION" => "Bearer audit-secret", "REMOTE_ADDR" => "10.1.1.1"))
        Rails.application.call(Rack::MockRequest.env_for(endpoint_path, "HTTP_AUTHORIZATION" => "Bearer wrong-secret"))
      end

      expect(entries.size).to eq(2)
      expect(entries.first).to include("v" => 1, "action" => "read", "result" => "served", "status" => 200, "key" => blob.key,
        "filename" => "members.csv", "byte_size" => Documents::BYTES.bytesize, "node" => "node-a", "remote_ip" => "10.1.1.1",
        "auth" => ["token"], "identity" => "node", "hop" => false)
      expect(entries.first).to include("at", "duration_ms")
      expect(entries.last).to include("result" => "unauthorized", "status" => 401)
      expect(File.read(path)).not_to include("secret")
      expect(File.read(path)).not_to include(Documents::BYTES)
    end

    it "records a remote fetch with the nodes' outcomes" do
      multi_node_disk_move(blob, to: node_b)
      multi_node_disk_cluster("node-b" => node_b, "node-c" => :missing) { blob.download }

      fetch = entries.find { |entry| entry["action"] == "fetch" }
      expect(fetch).to include("result" => "served", "node" => "node-b", "from_node" => "node-a", "key" => blob.key)
      served = entries.find { |entry| entry["action"] == "read" }
      expect(served).to include("hop" => true, "from_node" => "node-a", "node" => "node-b")
    end

    it "records a remote delete" do
      multi_node_disk_cluster("node-b" => :missing, "node-c" => :down) do
        expect { ActiveStorage::Blob.service.delete(blob.key) }.to raise_error(ActiveStorage::MultiNodeDisk::Unavailable)
      end
      expect(entries.find { |entry| entry["action"] == "remote_delete" }).to include("result" => "error")
    end

    it "keeps lines whole when threads and processes write at once" do
      sink = ActiveStorage::MultiNodeDisk::FileSink.instance
      big = {"filler" => "x" * 10_000}
      pids = Array.new(2) { fork { 20.times { sink.write(path, big) } } }
      Array.new(4) { Thread.new { 20.times { sink.write(path, big) } } }.each(&:join)
      pids.each { |pid| Process.wait(pid) }

      expect(entries.size).to eq(120)
      expect(entries.uniq).to eq([big])
    end

    it "merges the host's context and requester" do
      context = ->(request, entry) { {source_id: 7, from_request: !request.nil?, about: entry[:key]} }
      ActiveStorage::MultiNodeDisk.with_config(audit_context: context, audit_requester: ->(_) { {id: 1, label: "hr@example.com", type: "hr_admin"} }) do
        Rails.application.call(Rack::MockRequest.env_for(endpoint_path))
      end

      expect(entries.last).to include("context" => {"source_id" => 7, "from_request" => true, "about" => blob.key},
        "requester" => {"id" => 1, "label" => "hr@example.com", "type" => "hr_admin"})
    end

    it "is instrumented as audit.multi_node_disk" do
      received = []
      subscriber = ActiveSupport::Notifications.subscribe("audit.multi_node_disk") { |*, payload| received << payload }
      Rails.application.call(Rack::MockRequest.env_for(endpoint_path))
      ActiveSupport::Notifications.unsubscribe(subscriber)

      expect(received.last).to include("action" => "read", "key" => blob.key)
    end
  end

  describe "the requester" do
    around { |example| ActiveStorage::MultiNodeDisk.with_config(audit_path: path) { example.run } }

    it "is set for a block with with_requester, recorded for a remote fetch and sent to the node that answers" do
      multi_node_disk_move(blob, to: node_b)
      user = {"id" => 42, "label" => "Uploader", "type" => "hr_admin"}

      with_token("t") do
        multi_node_disk_cluster("node-b" => node_b, "node-c" => :missing) do |requests|
          ActiveStorage::MultiNodeDisk.with_requester(user) { blob.download }
          expect(requests.find { |entry| entry[:node] == "node-b" }[:headers]).to include("X-Multi-Node-Disk-Requester")
        end
      end

      expect(entries.find { |entry| entry["action"] == "fetch" }["requester"]).to eq(user)
      served = entries.find { |entry| entry["action"] == "read" }
      expect(served).to include("requester" => user, "requester_verified" => true)
      expect(ActiveStorage::MultiNodeDisk.current_requester).to be_nil
    end

    it "is recorded as unverified under :none" do
      header = JSON.generate("id" => 9, "label" => "Someone")
      Rails.application.call(Rack::MockRequest.env_for(endpoint_path, "HTTP_X_MULTI_NODE_DISK_REQUESTER" => header))

      expect(entries.last).to include("requester" => {"id" => 9, "label" => "Someone"}, "requester_verified" => false)
    end

    it "is dropped when it is larger than the cap, sent or received" do
      huge = {"label" => "x" * ActiveStorage::MultiNodeDisk::Requester::MAX_BYTES}
      expect(ActiveStorage::MultiNodeDisk::Requester.encode(huge)).to be_nil
      expect(ActiveStorage::MultiNodeDisk::Requester.decode(JSON.generate(huge))).to be_nil
      expect(ActiveStorage::MultiNodeDisk::Requester.decode("not json")).to be_nil
    end
  end

  describe "other sinks" do
    it ":none writes nothing" do
      ActiveStorage::MultiNodeDisk.with_config(audit: :none, audit_path: path) { Rails.application.call(Rack::MockRequest.env_for(endpoint_path)) }
      expect(File.exist?(path)).to be(false)
    end

    it "a callable receives each entry" do
      seen = []
      ActiveStorage::MultiNodeDisk.with_config(audit: ->(entry) { seen << entry }) { Rails.application.call(Rack::MockRequest.env_for(endpoint_path)) }
      expect(seen.last).to include("action" => "read")
    end

    it "a failing sink never fails the request" do
      ActiveStorage::MultiNodeDisk.with_config(audit: ->(_) { raise "disk full" }) do
        status, = Rails.application.call(Rack::MockRequest.env_for(endpoint_path))
        expect(status).to eq(200)
      end
    end
  end
end

RSpec.describe "Audit edges" do
  let(:blob) { document_with_file.file.blob }
  let(:path) { Rails.root.join("tmp/audit-edges-#{SecureRandom.hex(4)}.log") }
  let(:entries) { File.readlines(path).map { |line| JSON.parse(line) } }

  around { |example| ActiveStorage::MultiNodeDisk.with_config(audit_path: path) { example.run } }
  after { FileUtils.rm_f(path) }

  it "marks the requester verified on an authenticated miss, and not on a refused request" do
    header = JSON.generate("id" => 3)
    with_token("t") do
      Rails.application.call(Rack::MockRequest.env_for("/rails/active_storage/multi_node_disk/blobs/missing", "HTTP_AUTHORIZATION" => "Bearer t", "HTTP_X_MULTI_NODE_DISK_REQUESTER" => header))
      Rails.application.call(Rack::MockRequest.env_for("/rails/active_storage/multi_node_disk/blobs/missing", "HTTP_AUTHORIZATION" => "Bearer no", "HTTP_X_MULTI_NODE_DISK_REQUESTER" => header))
    end

    expect(entries.map { |entry| [entry["status"], entry["requester_verified"]] }).to eq([[404, true], [401, false]])
  end

  it "keeps the requester of a queued delete when the job runs later" do
    ActiveStorage::MultiNodeDisk.with_config(delete_mode: :job) do
      ActiveStorage::MultiNodeDisk.with_requester({"id" => 5, "label" => "Purger"}) { ActiveStorage::Blob.service.delete(blob.key) }
    end
    job = ActiveJob::Base.queue_adapter.enqueued_jobs.last

    multi_node_disk_cluster("node-b" => :missing, "node-c" => :missing) do
      ActiveJob::Base.execute(job)
    end
    expect(entries.find { |entry| entry["action"] == "remote_delete" }["requester"]).to eq("id" => 5, "label" => "Purger")
  end
end

RSpec.describe ActiveStorage::MultiNodeDisk::Configuration, "table prefix length" do
  it "refuses a prefix whose Oracle sequence name would pass 30 characters" do
    config = described_class.new
    config.table_name_prefix = "a" * described_class::MAX_PREFIX
    expect(config.validate!).to eq(config)
    config.table_name_prefix = "a" * (described_class::MAX_PREFIX + 1)
    expect { config.validate! }.to raise_error(ActiveStorage::MultiNodeDisk::ConfigurationError, /at most 20/)
  end
end
