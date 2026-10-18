# frozen_string_literal: true

require "rails_helper"

# A node's endpoint: request auth by mode, then this disk only.
RSpec.describe "Node endpoint", type: :request do
  let(:blob) { document_with_file.file.blob }
  let(:path) { "/rails/active_storage/multi_node_disk/blobs/#{blob.key}" }
  let(:events) { [] }

  around do |example|
    subscriber = ActiveSupport::Notifications.subscribe(/multi_node_disk\z/) { |name, *, payload| events << [name, payload] }
    example.run
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  def bearer(token) = {"Authorization" => "Bearer #{token}"}

  context "with :none (the default)" do
    it "serves the file, a HEAD and a DELETE without any credential" do
      get path
      expect(response).to have_http_status(:ok)
      expect(response.body).to eq(Documents::BYTES)
      expect(response.headers["X-Multi-Node-Disk-Node"]).to eq("node-a")

      head path
      expect(response).to have_http_status(:ok)

      delete path
      expect(response).to have_http_status(:no_content)
      expect(File.exist?(ActiveStorage::Blob.service.path_for(blob.key))).to be(false)
    end

    it "answers 404 as itself for a file not on this disk, and never asks another node" do
      FileUtils.rm(ActiveStorage::Blob.service.path_for(blob.key))

      multi_node_disk_cluster("node-b" => :missing, "node-c" => :missing) do |requests|
        get path, headers: {"X-Multi-Node-Disk-Hop" => "1"}
        expect(response).to have_http_status(:not_found)
        expect(response.parsed_body).to include("node" => "node-a")
        get "/rails/active_storage/multi_node_disk/blobs/no-such-key"
        expect(response).to have_http_status(:not_found)
        expect(requests).to be_empty
      end
    end

    it "answers a DELETE for a key with no row (the broadcast after a purge) with 204" do
      delete "/rails/active_storage/multi_node_disk/blobs/gone-key"
      expect(response).to have_http_status(:no_content)
    end
  end

  context "with :token" do
    around { |example| with_token("node-secret") { example.run } }

    it "refuses a missing token with 401 and a Bearer challenge" do
      get path
      expect(response).to have_http_status(:unauthorized)
      expect(response.headers["WWW-Authenticate"]).to eq('Bearer realm="Multi-node disk"')
      expect(events.map(&:first)).to include("denied.multi_node_disk")
    end

    it "refuses a wrong token, and the Token scheme, with 401" do
      get path, headers: bearer("guess")
      expect(response).to have_http_status(:unauthorized)

      get path, headers: {"Authorization" => "Token node-secret"}
      expect(response).to have_http_status(:unauthorized)
    end

    it "serves the right token" do
      get path, headers: bearer("node-secret")
      expect(response).to have_http_status(:ok)
      expect(events.map(&:first)).to include("serve.multi_node_disk")
    end

    it "passes the token and the request to authenticate, and refuses what it refuses" do
      seen = []
      authenticate = ->(token, request) { seen << [token, request.class] && nil }

      ActiveStorage::MultiNodeDisk.with_config(authenticate: authenticate) { get path, headers: bearer("anything") }
      expect(response).to have_http_status(:unauthorized)
      expect(seen).to eq([["anything", ActionDispatch::Request]])
    end

    it "keeps the token out of the log and the events" do
      Dummy::Application::LOG.truncate(0)
      get path, headers: bearer("node-secret")
      get path, headers: bearer("wrong-secret")

      expect(Dummy::Application::LOG.string).not_to include("node-secret")
      expect(Dummy::Application::LOG.string).not_to include("wrong-secret")
      expect(events.to_s).not_to include("secret")
    end
  end

  context "with :ip" do
    # A resolver with a fixed answer (built in an around hook, so no rspec double).
    let(:resolver) { Struct.new(:answers) { def getaddresses(name) = answers.fetch(name, []) }.new({"node-b" => ["10.0.0.2"]}) }
    let(:addresses) { ActiveStorage::MultiNodeDisk::NodeAddresses.new(resolver: resolver) }

    around do |example|
      saved = ActiveStorage::MultiNodeDisk.node_addresses
      ActiveStorage::MultiNodeDisk.node_addresses = addresses
      ActiveStorage::MultiNodeDisk.with_config(auth: :ip) { example.run }
    ensure
      ActiveStorage::MultiNodeDisk.node_addresses = saved
    end

    it "admits a node's address and refuses any other with 403" do
      get path, env: {"REMOTE_ADDR" => "10.0.0.2"}
      expect(response).to have_http_status(:ok)

      get path, env: {"REMOTE_ADDR" => "10.0.0.9"}
      expect(response).to have_http_status(:forbidden)
    end

    it "takes an explicit list of IPs and CIDRs instead" do
      ActiveStorage::MultiNodeDisk.with_config(allowed_ips: ["192.168.5.0/24"]) do
        get path, env: {"REMOTE_ADDR" => "192.168.5.77"}
        expect(response).to have_http_status(:ok)
        get path, env: {"REMOTE_ADDR" => "10.0.0.2"}
        expect(response).to have_http_status(:forbidden)
      end
    end

    it "ignores X-Forwarded-For unless the peer is a proxy the app trusts" do
      # No proxies configured: only the socket's peer counts.
      get path, env: {"REMOTE_ADDR" => "203.0.113.7", "HTTP_X_FORWARDED_FOR" => "10.0.0.2"}
      expect(response).to have_http_status(:forbidden)
      get path, env: {"REMOTE_ADDR" => "192.168.9.9", "HTTP_X_FORWARDED_FOR" => "10.0.0.2"}
      expect(response).to have_http_status(:forbidden)
    end

    it "reads the forwarded address through a proxy the app names in trusted_proxies" do
      settings = Rails.application.config.action_dispatch
      saved = settings.trusted_proxies
      settings.trusted_proxies = [IPAddr.new("192.168.9.9")]
      allow_any_instance_of(ActionDispatch::Request).to receive(:remote_ip).and_return("10.0.0.2") # standard:disable RSpec/AnyInstance

      get path, env: {"REMOTE_ADDR" => "192.168.9.9", "HTTP_X_FORWARDED_FOR" => "10.0.0.2"}
      expect(response).to have_http_status(:ok)
      get path, env: {"REMOTE_ADDR" => "203.0.113.7", "HTTP_X_FORWARDED_FOR" => "10.0.0.2"}
      expect(response).to have_http_status(:forbidden)
    ensure
      settings.trusted_proxies = saved
    end
  end

  context "with [:ip, :token]" do
    around do |example|
      ActiveStorage::MultiNodeDisk.with_config(auth: %i[ip token], token: "node-secret", allowed_ips: ["10.0.0.2"]) { example.run }
    end

    it "needs both: a wrong address is 403, a wrong token 401, both right 200" do
      get path, headers: bearer("node-secret"), env: {"REMOTE_ADDR" => "10.0.0.9"}
      expect(response).to have_http_status(:forbidden)

      get path, headers: bearer("guess"), env: {"REMOTE_ADDR" => "10.0.0.2"}
      expect(response).to have_http_status(:unauthorized)

      get path, headers: bearer("node-secret"), env: {"REMOTE_ADDR" => "10.0.0.2"}
      expect(response).to have_http_status(:ok)
    end
  end
end
