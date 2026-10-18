# frozen_string_literal: true

require "socket"
require "rails"
require "active_storage"
require "active_storage/engine"
require "action_controller"
require "zeitwerk"

loader = Zeitwerk::Loader.for_gem_extension(ActiveStorage)
# Active Storage's Configurator requires the service by path
# (`service: MultiNodeDisk` in storage.yml), as it does S3Service.
loader.ignore("#{__dir__}/service")
# Active Job is optional: the job loads only in :job delete mode.
loader.ignore("#{__dir__}/multi_node_disk/delete_job.rb")
loader.setup
# Also by constant, for code that names the class before storage.yml built it.
ActiveStorage::Service.autoload(:MultiNodeDiskService, "active_storage/service/multi_node_disk_service")

module ActiveStorage
  # Helpers for ActiveStorage::Service::MultiNodeDiskService, a Disk service
  # for apps on several nodes, each with its own disk.
  #
  # 1. Upload: Disk writes the file to this node's disk.
  # 2. Read, exist?: this disk first; else every other node is asked in
  #    parallel (FanOut), and the first answer that matches the blob's size
  #    and checksum wins.
  # 3. Delete: this disk, then every other node.
  # 4. A node's endpoint (BlobsController) answers from its own disk only,
  #    so a hop never fans out.
  #
  # Defaults are plain Rails 8.1; a host changes them once, in an
  # initializer (`ActiveStorage::MultiNodeDisk.configure`).
  module MultiNodeDisk
    # Every endpoint response names the node that answered.
    NODE_HEADER = "X-Multi-Node-Disk-Node"
    # Rack env key naming the service an in-process request is answered from
    # (TestHelper). HTTP cannot set it: header keys are HTTP_*.
    SERVICE_ENV_KEY = "active_storage_multi_node_disk.service"

    class << self
      # @return [ActiveStorage::MultiNodeDisk::Configuration]
      def config
        @config ||= Configuration.new
      end

      # Sets the hooks, in an initializer.
      #
      # @yieldparam config [ActiveStorage::MultiNodeDisk::Configuration]
      # @raise [ConfigurationError] once the app has booted (frozen)
      def configure
        raise ConfigurationError, "configure runs in an initializer; the configuration is frozen after boot" if config.frozen?

        yield config
      end

      # Validates and freezes the configuration (the engine, after boot),
      # and checks storage.yml: at most one MultiNodeDisk service (the
      # endpoint serves one disk root), with a node list.
      #
      # @param services [Hash] storage.yml, by service name
      # @return [ActiveStorage::MultiNodeDisk::Configuration]
      def finalize!(services = service_configurations)
        check_services!(services)
        return config if config.frozen?

        config.validate!.freeze
        warn_unprotected
        config
      end

      # The cache of node addresses for the :ip check.
      #
      # @return [NodeAddresses]
      def node_addresses
        @node_addresses ||= NodeAddresses.new
      end

      attr_writer :node_addresses

      # Where the endpoint is mounted: under Active Storage's routes prefix.
      #
      # @return [String]
      def mount_path
        "#{ActiveStorage.routes_prefix || "/rails/active_storage"}/multi_node_disk"
      end

      # Runs the block with some options replaced (tests).
      #
      # @param overrides [Hash{Symbol => Object}]
      def with_config(**overrides)
        previous = config
        @config = previous.merge(**overrides)
        yield
      ensure
        @config = previous
      end

      # The app's MultiNodeDisk service (storage.yml has at most one).
      #
      # @return [ActiveStorage::Service::MultiNodeDiskService, nil]
      def service
        name = service_configurations.find { |_, options| options.to_h.with_indifferent_access[:service].to_s == "MultiNodeDisk" }&.first
        ActiveStorage::Blob.services.fetch(name) if name
      end

      # storage.yml, read as Active Storage reads it (which it does only
      # when ActiveStorage::Blob first loads).
      #
      # @return [Hash]
      def service_configurations
        configured = Rails.configuration.active_storage.service_configurations
        return configured.to_h if configured

        file = Rails.root.join("config/storage/#{Rails.env}.yml")
        file = Rails.root.join("config/storage.yml") unless file.exist?
        file.exist? ? ActiveSupport::ConfigurationFile.parse(file).to_h : {}
      end

      # Runs the block on behalf of someone (a job's user): remote fetches and
      # deletes in it record them, here and on the node that answers.
      #
      # @param requester [Hash, nil] e.g. {id:, label:, type:}; never a secret
      def with_requester(requester, &)
        Requester.with(requester, &)
      end

      # @return [Hash, nil] the requester with_requester set
      def current_requester
        Requester.current
      end

      # The shared node token from Rails credentials (`multi_node_disk.token`).
      #
      # @return [String, nil]
      def credentials_token
        Rails.application.credentials.dig(:multi_node_disk, :token).presence
      end

      # Instruments `<event>.multi_node_disk`. Payloads never carry a token.
      #
      # @param event [Symbol]
      # @param payload [Hash]
      def instrument(event, payload = {}, &)
        ActiveSupport::Notifications.instrument("#{event}.multi_node_disk", payload, &)
      end

      private

      # One warning at boot in production while the endpoint has no check.
      def warn_unprotected
        return unless Rails.env.production? && service&.auth_modes == [:none]

        Rails.logger&.warn("[ActiveStorage::MultiNodeDisk] auth is :none: anyone who can reach #{mount_path} can read and delete files. Set config.auth to :token, :ip or [:ip, :token].")
      end

      def check_services!(services)
        ours = services.to_h.select { |_, options| options.to_h.with_indifferent_access[:service].to_s == "MultiNodeDisk" }
        raise ConfigurationError, "storage.yml has #{ours.size} MultiNodeDisk services (#{ours.keys.join(", ")}); one serves the endpoint" if ours.size > 1

        ours.each do |name, options|
          next unless options.to_h.with_indifferent_access[:nodes].nil? && config.nodes.nil?

          raise ConfigurationError, "storage.yml #{name}: MultiNodeDisk needs nodes: (or config.nodes)"
        end
      end
    end
  end
end

# Loaded now, so Rails sees the engine (its controller, job and routes).
require "active_storage/multi_node_disk/engine"
