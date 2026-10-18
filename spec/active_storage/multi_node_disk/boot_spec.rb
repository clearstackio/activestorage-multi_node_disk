# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Boot checks" do
  def finalize(services, config = ActiveStorage::MultiNodeDisk::Configuration.new)
    ActiveStorage::MultiNodeDisk.instance_variable_set(:@config, config)
    ActiveStorage::MultiNodeDisk.finalize!(services)
  end

  around do |example|
    saved = ActiveStorage::MultiNodeDisk.config
    example.run
  ensure
    ActiveStorage::MultiNodeDisk.instance_variable_set(:@config, saved)
  end

  it "refuses two MultiNodeDisk services (the endpoint serves one disk)" do
    services = {a: {service: "MultiNodeDisk", root: "/a", nodes: ["x"]}, b: {service: "MultiNodeDisk", root: "/b", nodes: ["x"]}}
    expect { finalize(services) }.to raise_error(ActiveStorage::MultiNodeDisk::ConfigurationError, /2 MultiNodeDisk services/)
  end

  it "refuses a MultiNodeDisk service without a node list" do
    expect { finalize({local: {service: "MultiNodeDisk", root: "/a"}}) }
      .to raise_error(ActiveStorage::MultiNodeDisk::ConfigurationError, /local: MultiNodeDisk needs nodes/)
  end

  it "accepts the node list from config.nodes" do
    config = ActiveStorage::MultiNodeDisk::Configuration.new.tap { |c| c.nodes = -> { ["x"] } }
    expect(finalize({local: {service: "MultiNodeDisk", root: "/a"}}, config)).to be_frozen
  end

  it "warns once at boot in production while the endpoint checks nothing" do
    allow(Rails.env).to receive(:production?).and_return(true)
    expect(Rails.logger).to receive(:warn).with(/auth is :none/).once

    finalize(Rails.configuration.active_storage.service_configurations)
  end

  it "does not warn when the endpoint checks a token" do
    allow(Rails.env).to receive(:production?).and_return(true)
    expect(Rails.logger).not_to receive(:warn)

    finalize(Rails.configuration.active_storage.service_configurations, ActiveStorage::MultiNodeDisk::Configuration.new.tap { |c| c.auth = :token })
  end
end
