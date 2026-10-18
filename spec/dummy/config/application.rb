# frozen_string_literal: true

require "logger"
require "rails"
require "active_record/railtie"
require "active_job/railtie"
require "active_storage/engine"
require "action_controller/railtie"
require "activestorage-multi_node_disk"

module Dummy
  # A minimal host: SQLite, one MultiNodeDisk service for three nodes.
  class Application < Rails::Application
    config.load_defaults 8.1
    config.root = File.expand_path("..", __dir__)
    config.eager_load = false
    config.hosts.clear
    config.secret_key_base = "multi-node-disk-dummy"
    config.logger = ActiveSupport::Logger.new(LOG = StringIO.new)
    config.log_level = :debug
    config.active_storage.service = :local
    config.active_job.queue_adapter = :test
    config.action_dispatch.show_exceptions = :none
  end
end
