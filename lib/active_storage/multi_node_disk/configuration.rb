# frozen_string_literal: true

require "ipaddr"

module ActiveStorage
  module MultiNodeDisk
    # The hooks a host may change. Each default is what a plain Rails 8.1 app
    # would do; a host sets only what differs, in one initializer:
    #
    #   ActiveStorage::MultiNodeDisk.configure do |config|
    #     config.url_for = ->(node, key) { "https://#{node}:8443#{ActiveStorage::MultiNodeDisk.mount_path}/blobs/#{key}" }
    #   end
    #
    # The engine validates and freezes it when the app has booted; threads
    # then share it read-only.
    class Configuration
      # Hooks that must be callables (the security hooks among them: a
      # static `true` must never authenticate).
      CALLABLES = %i[url_for authenticate error_mapper].freeze
      # Hooks that may be a value or a callable.
      VALUES = %i[current_node nodes token token_for].freeze
      TIMEOUTS = %i[open_timeout read_timeout].freeze
      OPTIONS = (CALLABLES + VALUES + TIMEOUTS + %i[auth allowed_ips http_client hop_header requester_header draw_routes delete_mode delete_job_queue delete_job_class audit audit_path audit_context audit_requester table_name_prefix]).freeze
      AUTH_MODES = %i[none token ip].freeze
      DELETE_MODES = %i[sync job].freeze
      AUDIT_SINKS = %i[none file table].freeze
      # Longest table_name_prefix: "<prefix>audits_seq" must fit in 30.
      MAX_PREFIX = 30 - "audits_seq".length
      HEADER_NAME = /\A[A-Za-z0-9-]+\z/

      # @return [String, #call] this node: `-> String` (storage.yml `node:` wins)
      attr_accessor :current_node
      # @return [Array<String>, #call] every node: `-> Array` (storage.yml `nodes:` wins)
      attr_accessor :nodes
      # @return [#call] a node's URL for a file: `(node, key) -> String`, https only
      attr_accessor :url_for
      # @return [Symbol, Array<Symbol>] the endpoint's checks: :none (the
      #   default: no check at all), :token, :ip, or [:ip, :token] (both)
      attr_accessor :auth
      # @return [Array<String>, nil] IPs and CIDRs for :ip (nil: every node's
      #   addresses, resolved by DNS and refreshed every NodeAddresses::TTL)
      attr_accessor :allowed_ips
      # @return [String, #call] the shared token for :token: `-> String`
      attr_accessor :token
      # @return [String, #call] the token sent to a node: `(node, blob, action) -> String`
      attr_accessor :token_for
      # @return [#call] whether a token is a node's, for :token:
      #   `(token, request) -> identity or nil` (nil refuses)
      attr_accessor :authenticate
      # @return [#call] `#call(method, url, headers:, node:, open_timeout:, read_timeout:) -> Response`;
      #   called from several threads at once, so it must not share a connection
      attr_accessor :http_client
      # @return [String] the header that marks a node-to-node request
      attr_accessor :hop_header
      # @return [Numeric] seconds
      attr_accessor :open_timeout, :read_timeout
      # @return [#call] `(error) -> Exception`, raised in place of the gem's error
      attr_accessor :error_mapper
      # @return [Boolean] whether the gem mounts its endpoint at mount_path
      attr_accessor :draw_routes
      # @return [String] the header that carries the requester to another node
      attr_accessor :requester_header
      # @return [Symbol, #call] where audit entries go: :file (default),
      #   :table, :none, or a callable given each entry
      attr_accessor :audit
      # @return [String, Pathname] the :file sink's file
      attr_accessor :audit_path
      # @return [#call, nil] more for each entry: `(request or nil, entry) -> Hash`
      #   (the entry so far: action, key and the rest)
      attr_accessor :audit_context
      # @return [#call, nil] who it is for: `(request or nil) -> Hash`
      #   (with_requester wins; the gem never reads it)
      attr_accessor :audit_requester
      # @return [String] the prefix of the gem's tables (the audit table)
      attr_accessor :table_name_prefix
      # @return [Symbol] how delete reaches the other nodes: :sync (inline,
      #   raising Unavailable when one does not confirm) or :job (DeleteJob)
      attr_accessor :delete_mode
      # @return [String, Symbol, nil] DeleteJob's queue (nil: Active Storage's purge queue)
      attr_accessor :delete_job_queue
      # @return [String, Class, nil] a DeleteJob subclass (other retries)
      attr_accessor :delete_job_class

      def initialize
        @current_node = -> { Socket.gethostname }
        @nodes = nil
        @url_for = ->(node, key) { "https://#{node}#{MultiNodeDisk.mount_path}/blobs/#{key}" }
        @auth = :none
        @allowed_ips = nil
        @token = -> { MultiNodeDisk.credentials_token }
        @token_for = ->(_node, _blob, _action) { MultiNodeDisk.config.resolve(:token) }
        @authenticate = ->(token, _request) { :node if Configuration.token?(token) }
        @http_client = NetHttpClient.new
        @hop_header = "X-Multi-Node-Disk-Hop"
        @open_timeout = 3
        @read_timeout = 20
        @error_mapper = ->(error) { error }
        @draw_routes = true
        @requester_header = "X-Multi-Node-Disk-Requester"
        @audit = :file
        @audit_path = Rails.root.join("tmp/multi_node_disk/audit.log")
        @audit_context = nil
        @audit_requester = nil
        @table_name_prefix = "multi_node_disk_"
        @delete_mode = :sync
        @delete_job_queue = nil
        @delete_job_class = nil
      end

      # The default authenticate: config.token (by default the credentials
      # token), compared in constant time. No token configured: nobody.
      #
      # @param token [String, nil]
      # @return [Boolean]
      def self.token?(token)
        expected = MultiNodeDisk.config.resolve(:token).to_s
        expected.present? && token.present? && ActiveSupport::SecurityUtils.secure_compare(token, expected)
      end

      # @param auth [Symbol, String, Array]
      # @return [Array<Symbol>] the modes
      # @raise [ConfigurationError] for an unknown mode, none, or :none combined
      def self.auth_modes(auth)
        modes = Array(auth).map { |mode| mode.to_s.to_sym }.uniq
        valid = modes.any? && (modes - AUTH_MODES).empty? && (modes == [:none] || !modes.include?(:none))
        raise ConfigurationError, "ActiveStorage::MultiNodeDisk auth must be :none, :token, :ip or [:ip, :token] (got #{auth.inspect})" unless valid

        modes
      end

      # @param list [Array<String>, nil]
      # @return [Array<IPAddr>, nil]
      # @raise [ConfigurationError] for an entry that is not an IP or CIDR
      def self.ip_list(list)
        return if list.nil?

        Array(list).map { |entry| IPAddr.new(entry.to_s.strip) }
      rescue IPAddr::Error
        raise ConfigurationError, "ActiveStorage::MultiNodeDisk allowed_ips: #{list.inspect} holds an entry that is not an IP or CIDR"
      end

      # @param value [Object]
      # @return [Boolean] a positive, finite number
      def self.seconds?(value)
        value.is_a?(Numeric) && value.positive? && value.finite?
      end

      # The option's value, called with the arguments when it is callable.
      #
      # @param option [Symbol]
      # @return [Object]
      def resolve(option, *args)
        value = public_send(option)
        value.respond_to?(:call) ? value.call(*args) : value
      end

      # @return [self]
      # @raise [ConfigurationError] naming the first option that is wrong
      def validate!
        CALLABLES.each { |option| fail_option(option, "must respond to call") unless public_send(option).respond_to?(:call) }
        %i[current_node token token_for].each { |option| string_or_callable!(option) }
        Configuration.auth_modes(auth)
        fail_option(:delete_mode, "must be :sync or :job") unless DELETE_MODES.include?(delete_mode.to_s.to_sym)
        delete_job if delete_mode.to_s == "job"
        Configuration.ip_list(allowed_ips)
        fail_option(:nodes, "must be an Array or respond to call") unless nodes.nil? || nodes.is_a?(Array) || nodes.respond_to?(:call)
        fail_option(:http_client, "must respond to call") unless http_client.respond_to?(:call)
        %i[hop_header requester_header].each { |option| fail_option(option, "must be a header name") unless public_send(option).is_a?(String) && HEADER_NAME.match?(public_send(option)) }
        %i[audit_context audit_requester].each { |option| fail_option(option, "must be nil or respond to call") unless public_send(option).nil? || public_send(option).respond_to?(:call) }
        fail_option(:audit, "must be :file, :table, :none or respond to call") unless audit.respond_to?(:call) || AUDIT_SINKS.include?(audit.to_s.to_sym)
        fail_option(:table_name_prefix, "must be a lowercase identifier prefix") unless table_name_prefix.is_a?(String) && table_name_prefix.match?(/\A[a-z][a-z0-9_]*\z/)
        # "<prefix>audits_seq" (the sequence Oracle's adapter adds) within 30.
        fail_option(:table_name_prefix, "must be at most #{MAX_PREFIX} characters (Oracle's 30-character names)") if table_name_prefix.length > MAX_PREFIX
        TIMEOUTS.each { |option| fail_option(option, "must be a positive, finite number of seconds") unless Configuration.seconds?(public_send(option)) }
        self
      end

      # The job for :job mode, loading Active Job and the gem's job.
      #
      # @return [Class]
      # @raise [ConfigurationError] when Active Job is not available
      def delete_job
        begin
          require "active_job"
          require "active_storage/multi_node_disk/delete_job"
        rescue LoadError => error
          raise ConfigurationError, "ActiveStorage::MultiNodeDisk delete_mode :job needs Active Job (#{error.message})"
        end
        job = delete_job_class.is_a?(String) ? delete_job_class.constantize : (delete_job_class || DeleteJob)
        fail_option(:delete_job_class, "must be ActiveStorage::MultiNodeDisk::DeleteJob or a subclass") unless job.is_a?(Class) && job <= DeleteJob
        job
      end

      # A validated, frozen copy with some options replaced.
      #
      # @param overrides [Hash{Symbol => Object}]
      # @return [Configuration]
      def merge(**overrides)
        unknown = overrides.keys - OPTIONS
        raise ConfigurationError, "unknown option #{unknown.first}" if unknown.any?

        dup.tap { |copy| overrides.each { |option, value| copy.public_send(:"#{option}=", value) } }.validate!.freeze
      end

      private

      def string_or_callable!(option)
        value = public_send(option)
        fail_option(option, "must be a String or respond to call") unless value.is_a?(String) || value.respond_to?(:call)
      end

      def fail_option(option, problem)
        raise ConfigurationError, "ActiveStorage::MultiNodeDisk config.#{option} #{problem}"
      end
    end
  end
end
