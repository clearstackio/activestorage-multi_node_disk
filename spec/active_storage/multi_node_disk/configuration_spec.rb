# frozen_string_literal: true

require "rails_helper"

RSpec.describe ActiveStorage::MultiNodeDisk::Configuration do
  subject(:config) { described_class.new }

  describe "defaults (plain Rails)" do
    it "names this node after the machine" do
      expect(config.resolve(:current_node)).to eq(Socket.gethostname)
    end

    it "checks nothing at the endpoint and sends no token" do
      expect(config).to have_attributes(auth: :none, allowed_ips: nil, hop_header: "X-Multi-Node-Disk-Hop",
        open_timeout: 3, read_timeout: 20, draw_routes: true)
      expect(config.http_client).to be_a(ActiveStorage::MultiNodeDisk::NetHttpClient)
    end

    it "builds the node URL under Active Storage's routes prefix" do
      expect(config.url_for.call("node-b", "abc")).to eq("https://node-b/rails/active_storage/multi_node_disk/blobs/abc")
    end

    it "takes the token from Rails credentials and admits only that token" do
      credentials = ActiveSupport::OrderedOptions.new.merge!(multi_node_disk: {token: "from-credentials"})
      allow(Rails.application).to receive(:credentials).and_return(credentials)

      expect(config.resolve(:token)).to eq("from-credentials")
      expect(config.resolve(:token_for, "node-b", nil, :read)).to eq("from-credentials")
      expect(config.authenticate.call("from-credentials", nil)).to eq(:node)
      expect(config.authenticate.call("other", nil)).to be_nil
    end

    it "admits nobody when no token is configured" do
      allow(Rails.application).to receive(:credentials).and_return(ActiveSupport::OrderedOptions.new)

      expect(config.authenticate.call("", nil)).to be_nil
      expect(config.authenticate.call("anything", nil)).to be_nil
    end
  end

  describe "#resolve" do
    it "calls a callable with the hook's arguments and returns a value as it is" do
      config.token_for = ->(node, blob, action) { [node, blob, action].join("/") }
      config.current_node = "node-z"

      expect(config.resolve(:token_for, "node-b", "blob", :delete)).to eq("node-b/blob/delete")
      expect(config.resolve(:current_node)).to eq("node-z")
    end
  end

  describe "#validate!" do
    {
      url_for: "https://x", authenticate: true, error_mapper: :raise,
      current_node: 42, token: 1, token_for: nil, nodes: "node-a", http_client: Object.new,
      hop_header: "Bad Header", open_timeout: 0, read_timeout: Float::INFINITY,
      auth: :password, allowed_ips: ["not-an-ip"]
    }.each do |option, value|
      it "refuses a bad #{option}" do
        config.public_send(:"#{option}=", value)
        expect { config.validate! }.to raise_error(ActiveStorage::MultiNodeDisk::ConfigurationError, /#{option}/)
      end
    end

    it "takes every auth mode and the combination, but not :none with another" do
      [:none, :token, :ip, [:ip, :token], %w[token ip]].each do |auth|
        config.auth = auth
        expect(config.validate!).to eq(config)
      end
      config.auth = [:none, :token]
      expect { config.validate! }.to raise_error(ActiveStorage::MultiNodeDisk::ConfigurationError, /auth/)
    end

    it "takes IPs and CIDRs" do
      config.allowed_ips = ["10.0.0.0/8", "192.168.1.5", "::1"]
      expect(config.validate!).to eq(config)
    end
  end

  describe "#merge" do
    it "returns a frozen, validated copy and leaves the original alone" do
      copy = config.merge(hop_header: "X-Other")

      expect(copy).to be_frozen
      expect(copy.hop_header).to eq("X-Other")
      expect(config.hop_header).to eq("X-Multi-Node-Disk-Hop")
      expect { config.merge(colour: :red) }.to raise_error(ActiveStorage::MultiNodeDisk::ConfigurationError, /colour/)
    end
  end

  describe "after boot" do
    it "is frozen, and configure refuses to change it" do
      expect(ActiveStorage::MultiNodeDisk.config).to be_frozen
      expect { ActiveStorage::MultiNodeDisk.configure { |c| c.hop_header = "X" } }
        .to raise_error(ActiveStorage::MultiNodeDisk::ConfigurationError, /frozen/)
    end

    it "with_config swaps options for a block and restores them" do
      ActiveStorage::MultiNodeDisk.with_config(hop_header: "X-Test") do
        expect(ActiveStorage::MultiNodeDisk.config.hop_header).to eq("X-Test")
      end
      expect(ActiveStorage::MultiNodeDisk.config.hop_header).to eq("X-Multi-Node-Disk-Hop")
    end
  end
end

RSpec.describe ActiveStorage::Service::MultiNodeDiskService, "storage.yml timeouts" do
  it "refuses a timeout that is not a positive, finite number" do
    ["3", -1, Float::INFINITY].each do |bad|
      expect { described_class.new(root: "/tmp/x", nodes: ["a"], open_timeout: bad) }
        .to raise_error(ActiveStorage::MultiNodeDisk::ConfigurationError, /open_timeout/)
    end
  end
end

RSpec.describe ActiveStorage::MultiNodeDisk::FanOut do
  it "returns within its deadline plus the shared cleanup budget, however many calls hang" do
    calls = (1..12).to_h { |n| ["n#{n}", -> { sleep }] }
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    described_class.run(calls, deadline: 0.05) { false }
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < (0.05 + described_class::JOIN_SECONDS + 0.5)
  end

  it "starts nothing after the deadline" do
    started = []
    calls = (1..12).to_h { |n| ["n#{n}", -> { started << n && sleep }] }

    described_class.run(calls, deadline: 0.05) { false }
    expect(started.size).to be <= described_class::MAX_THREADS
  end
end
