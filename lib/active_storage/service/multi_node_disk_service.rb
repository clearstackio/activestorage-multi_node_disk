# frozen_string_literal: true

require "active_storage/service/disk_service"
require "active_storage/multi_node_disk"

module ActiveStorage
  # = Active Storage \Multi-Node \Disk \Service
  #
  # Disk for an app on several nodes, each with its own disk. A file stays on
  # the disk of the node that received it. When a file is not on this disk,
  # every other node is asked at once and the first copy that matches the
  # blob wins; a delete deletes here and on every other node. Nothing is
  # recorded, so existing blobs work as they are.
  #
  #   local:
  #     service: MultiNodeDisk
  #     root: <%= Rails.root.join("storage") %>
  #     nodes: [app1.internal, app2.internal]
  #
  # Differs from Disk only in download, download_chunk, exist?, delete and
  # open, each calling super for a file on this disk. Keys without a blob
  # row (variants) and url, delete_prefixed and compose stay Disk's: local.
  class Service::MultiNodeDiskService < Service::DiskService
    LOCAL_DELETE = :active_storage_multi_node_disk_local_delete

    # @param root [String] this node's storage directory, as Disk
    # @param nodes [Array<String>, nil] every node, this one included (else config.nodes)
    # @param node [String, nil] this node (else config.current_node)
    # @param open_timeout [Numeric, nil] seconds (else config.open_timeout)
    # @param read_timeout [Numeric, nil] seconds (else config.read_timeout)
    # @param auth [Symbol, Array<Symbol>, nil] the endpoint's checks (else config.auth)
    # @param allowed_ips [Array<String>, nil] for :ip (else config.allowed_ips)
    def initialize(root:, public: false, nodes: nil, node: nil, open_timeout: nil, read_timeout: nil, auth: nil, allowed_ips: nil, **options)
      super(root: root, public: public, **options)
      @nodes_option = nodes
      @node_option = node
      @open_timeout = seconds!(:open_timeout, open_timeout)
      @read_timeout = seconds!(:read_timeout, read_timeout)
      @auth = auth && MultiNodeDisk::Configuration.auth_modes(auth)
      @allowed_ips = MultiNodeDisk::Configuration.ip_list(allowed_ips)
    end

    # Disk's upload. A file that fails its checksum is deleted here only,
    # never on the other nodes (Disk cleans up through #delete).
    def upload(key, io, checksum: nil, **)
      previous = ActiveSupport::IsolatedExecutionState[LOCAL_DELETE]
      ActiveSupport::IsolatedExecutionState[LOCAL_DELETE] = true
      super
    ensure
      ActiveSupport::IsolatedExecutionState[LOCAL_DELETE] = previous
    end

    # Disk's download. A whole file is checked against its blob; a file not
    # on this disk comes from the first node with a matching copy.
    def download(key, &block)
      blob = remote_blob(key)
      if blob.nil?
        block ? super : verify_local(key, super)
      elsif block
        instrument(:streaming_download, key: key) { each_chunk(fetch(key, blob), &block) }
      else
        instrument(:download, key: key) { fetch(key, blob) }
      end
    end

    def download_chunk(key, range)
      blob = remote_blob(key)
      return super unless blob

      instrument(:download_chunk, key: key, range: range) { fetch(key, blob).byteslice(range) }
    end

    # Whether any node has the file (presence, as Disk: not its checksum).
    def exist?(key)
      blob = remote_blob(key)
      return super unless blob

      instrument(:exist, key: key) do |payload|
        payload[:exist] = exist_elsewhere?(key, blob)
      end
    end

    # Deletes the file here, then on every other node: inline in :sync mode
    # (raising, as other services raise on a failed delete, once every node
    # was tried), or through DeleteJob in :job mode.
    #
    # @raise [MultiNodeDisk::Unavailable] in :sync mode, naming the nodes that did not confirm
    def delete(key)
      super
      return if ActiveSupport::IsolatedExecutionState[LOCAL_DELETE] || other_nodes.empty?

      config = MultiNodeDisk.config
      if config.delete_mode.to_s == "job"
        queue = config.delete_job_queue || ActiveStorage.queues[:purge]
        job = config.delete_job
        requester = MultiNodeDisk.current_requester || config.audit_requester&.call(nil)
        (queue ? job.set(queue: queue) : job).perform_later(name.to_s, key, other_nodes, requester&.as_json)
      else
        failed = delete_elsewhere(key)
        raise config.error_mapper.call(MultiNodeDisk::Unavailable.new(nodes: failed, key: key, reason: "delete not confirmed")) if failed.any?
      end
    end

    # Disk's open, with the integrity check raising the gem's Mismatch
    # (through the host's error_mapper). Errors from the block are its own.
    def open(key, checksum: nil, verify: true, **options)
      super(key, checksum: checksum, verify: false, **options) do |file|
        verify_file(key, file, checksum) if verify
        yield file
      end
    end

    # @return [String] this node's name
    # @raise [MultiNodeDisk::ConfigurationError] when it resolves blank
    def node
      found = (@node_option.presence || MultiNodeDisk.config.resolve(:current_node)).to_s
      raise MultiNodeDisk::ConfigurationError, "MultiNodeDisk: the current node resolved blank" if found.empty?

      found
    end

    # @return [Array<String>] every node, this one included
    # @raise [MultiNodeDisk::ConfigurationError] when no list is set
    def nodes
      list = @nodes_option.nil? ? MultiNodeDisk.config.resolve(:nodes) : @nodes_option
      raise MultiNodeDisk::ConfigurationError, "MultiNodeDisk needs nodes: in storage.yml (or config.nodes)" if list.nil?

      Array(list).map { |entry| entry.to_s.strip }.reject(&:empty?).uniq
    end

    # @return [Array<Symbol>] the endpoint's checks: [:none], [:token], [:ip] or [:ip, :token]
    def auth_modes
      @auth || MultiNodeDisk::Configuration.auth_modes(MultiNodeDisk.config.auth)
    end

    # @return [Array<IPAddr>] who may call the endpoint under :ip
    def allowed_ips
      @allowed_ips || MultiNodeDisk::Configuration.ip_list(MultiNodeDisk.config.allowed_ips) || MultiNodeDisk.node_addresses.for(nodes)
    end

    # @param key [String]
    # @return [Boolean] the file is on this node's disk
    def local?(key)
      File.exist?(path_for(key))
    end

    # Sends a delete to some nodes (all the others by default).
    #
    # @param key [String]
    # @param nodes [Array<String>]
    # @return [Array<String>] the nodes that did not confirm
    def delete_elsewhere(key, nodes: other_nodes)
      started = clock
      blob = ActiveStorage::Blob.find_by(key: key)
      outcomes = ask(nodes, :delete, key, blob, :delete) do |answering, response|
        (response.status == 204 && answered_by?(answering, response)) ? :deleted : :failed
      end
      MultiNodeDisk.instrument(:delete, key: key, outcomes: outcomes)
      failed = outcomes.select { |_, outcome| outcome == :failed }.keys
      audit(:remote_delete, failed.any? ? :error : :deleted, key, blob, outcomes, started)
      failed
    end

    private

    def other_nodes = nodes - [node]

    def seconds!(option, value)
      return if value.nil?
      return value if MultiNodeDisk::Configuration.seconds?(value)

      raise MultiNodeDisk::ConfigurationError, "MultiNodeDisk #{option}: in storage.yml must be a positive, finite number of seconds"
    end

    def open_timeout = @open_timeout || MultiNodeDisk.config.open_timeout

    def read_timeout = @read_timeout || MultiNodeDisk.config.read_timeout

    # The blob to look for elsewhere: nil when the file is here, or when no
    # blob row has the key (a variant: Disk's own, local behaviour).
    def remote_blob(key)
      return if local?(key)

      ActiveStorage::Blob.find_by(key: key)
    end

    # The first copy from another node that matches the blob.
    def fetch(key, blob)
      started = clock
      winner = nil
      outcomes = ask(other_nodes, :get, key, blob, :read) do |answering, response|
        next :failed unless response.status == 200
        next(winner = response.body) && :hit if matches?(blob, response.body)

        MultiNodeDisk.instrument(:mismatch, key: key, node: answering, byte_size: response.body.to_s.bytesize)
        :mismatch
      end
      MultiNodeDisk.instrument(:fetch, key: key, outcomes: outcomes)
      audit(:fetch, fetch_result(winner, outcomes), key, blob, outcomes, started)
      winner || raise_for(outcomes, key: key, filename: blob.filename)
    end

    def fetch_result(winner, outcomes)
      return :served if winner
      return :error if outcomes.value?(:failed)

      outcomes.value?(:mismatch) ? :mismatch : :not_found
    end

    def audit(action, result, key, blob, outcomes, started)
      MultiNodeDisk::AuditLog.record({
        action: action, result: result, key: key, filename: blob&.filename&.to_s, byte_size: blob&.byte_size,
        node: outcomes.key(:hit), from_node: node, outcomes: outcomes, auth: auth_modes, hop: false,
        duration_ms: ((clock - started) * 1000).round(1)
      })
    end

    def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    def exist_elsewhere?(key, blob)
      outcomes = ask(other_nodes, :head, key, blob, :read) { |_, response| (response.status == 200) ? :hit : :failed }
      MultiNodeDisk.instrument(:exist, key: key, outcomes: outcomes)
      return true if outcomes.value?(:hit)
      return false unless outcomes.value?(:failed)

      raise_for(outcomes, key: key, filename: blob.filename)
    end

    # Asks the nodes at once. The block classifies a response; a 404 from
    # the node addressed is :missing; an error, another node answering 404,
    # a node with no token and a node that never answered are :failed.
    # Stops at the first :hit.
    #
    # @return [Hash{String => Symbol}] each node's outcome
    def ask(targets, method, key, blob, action)
      requests = targets.to_h { |target| [target, request_for(method, target, key, blob, action)] }
      outcomes = {}
      MultiNodeDisk::FanOut.run(requests.compact, deadline: open_timeout + read_timeout) do |answering, result|
        outcomes[answering] = classify(answering, result) { |response| yield(answering, response) }
        outcomes[answering] == :hit
      end
      targets.each { |target| outcomes[target] ||= outcomes.value?(:hit) ? :skipped : :failed }
      outcomes
    end

    def classify(answering, result)
      return :failed unless result.is_a?(MultiNodeDisk::Response)
      return :missing if result.status == 404 && answered_by?(answering, result)

      yield result
    end

    def answered_by?(target, response)
      response.header(MultiNodeDisk::NODE_HEADER) == target
    end

    # The hooks run here, on the caller's thread; the callable returned runs
    # only the transport. Under :token, nil when no token is configured for
    # the node (so it counts as failed, unasked).
    def request_for(method, target, key, blob, action)
      config = MultiNodeDisk.config
      url = config.url_for.call(target, key).to_s
      raise MultiNodeDisk::ConfigurationError, "MultiNodeDisk url_for must return an https URL" unless url.start_with?("https://")

      headers = {config.hop_header => node}
      requester = MultiNodeDisk::Requester.encode(MultiNodeDisk.current_requester || config.audit_requester&.call(nil))
      headers[config.requester_header] = requester if requester
      if auth_modes.include?(:token)
        token = config.resolve(:token_for, target, blob, action).presence
        return unless token

        headers["Authorization"] = "Bearer #{token}"
      end
      client = config.http_client
      timeouts = {open_timeout: open_timeout, read_timeout: read_timeout}
      -> { MultiNodeDisk::Response.new(*client.call(method, url, headers: headers, node: target, **timeouts).to_a) }
    end

    def raise_for(outcomes, key:, filename:)
      failed = outcomes.select { |_, outcome| outcome == :failed }.keys
      mismatched = outcomes.select { |_, outcome| outcome == :mismatch }.keys
      error =
        if failed.any? then MultiNodeDisk::Unavailable.new(nodes: failed, key: key, filename: filename)
        elsif mismatched.any? then MultiNodeDisk::Mismatch.new(nodes: mismatched, key: key, filename: filename)
        else MultiNodeDisk::NotHere.new(nodes: nodes, key: key, filename: filename)
        end
      raise MultiNodeDisk.config.error_mapper.call(error)
    end

    def verify_local(key, bytes)
      blob = ActiveStorage::Blob.find_by(key: key)
      return bytes if blob.nil? || matches?(blob, bytes)

      mismatch_here(key, blob.filename)
    end

    def verify_file(key, file, checksum)
      return if checksum.present? && ActiveStorage.checksum_implementation.file(file.path).base64digest == checksum

      mismatch_here(key, ActiveStorage::Blob.find_by(key: key)&.filename)
    end

    def mismatch_here(key, filename)
      MultiNodeDisk.instrument(:mismatch, key: key, node: node)
      raise MultiNodeDisk.config.error_mapper.call(MultiNodeDisk::Mismatch.new(nodes: node, key: key, filename: filename))
    end

    def matches?(blob, bytes)
      bytes = bytes.to_s
      bytes.bytesize == blob.byte_size &&
        (blob.checksum.blank? || ActiveStorage.checksum_implementation.base64digest(bytes) == blob.checksum)
    end

    def each_chunk(bytes)
      offset = 0
      while offset < bytes.bytesize
        yield bytes.byteslice(offset, 5.megabytes)
        offset += 5.megabytes
      end
    end
  end
end
