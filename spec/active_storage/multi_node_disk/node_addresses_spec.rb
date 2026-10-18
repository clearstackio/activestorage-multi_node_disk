# frozen_string_literal: true

require "rails_helper"

RSpec.describe ActiveStorage::MultiNodeDisk::NodeAddresses do
  let(:answers) { {"node-b" => ["10.0.0.2"], "10.0.0.3" => ["10.0.0.3"]} }
  let(:resolver) { double("resolver") }
  let(:now) { [100.0] }
  let(:addresses) { described_class.new(resolver: resolver, clock: -> { now.first }) }

  before { allow(resolver).to receive(:getaddresses) { |name| answers.fetch(name) } }

  it "resolves each node, written as a name or an IP" do
    expect(addresses.for(%w[node-b 10.0.0.3]).map(&:to_s)).to eq(%w[10.0.0.2 10.0.0.3])
  end

  it "keeps answers for the TTL, then resolves again and picks up a new address" do
    addresses.for(["node-b"])
    answers["node-b"] = ["10.0.0.20"]

    now[0] += described_class::TTL - 1
    expect(addresses.for(["node-b"]).map(&:to_s)).to eq(["10.0.0.2"])
    now[0] += 2
    expect(addresses.for(["node-b"]).map(&:to_s)).to eq(["10.0.0.20"])
    expect(resolver).to have_received(:getaddresses).with("node-b").twice
  end

  it "keeps the last known addresses when a lookup fails" do
    addresses.for(["node-b"])
    allow(resolver).to receive(:getaddresses).and_raise(Resolv::ResolvError)
    now[0] += described_class::TTL + 1

    expect(addresses.for(["node-b"]).map(&:to_s)).to eq(["10.0.0.2"])
  end

  it "is shared by threads safely" do
    results = Array.new(8) { Thread.new { addresses.for(%w[node-b 10.0.0.3]).map(&:to_s) } }.map(&:value)
    expect(results.uniq).to eq([%w[10.0.0.2 10.0.0.3]])
  end
end
