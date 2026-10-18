# frozen_string_literal: true

module ActiveStorage
  module MultiNodeDisk
    # One node's endpoint for the others: a file from this node's disk only
    # (never asking further, so a hop cannot fan out), or its deletion.
    #
    # 1. The service's auth modes: :none checks nothing; :ip needs
    #    request.remote_ip in the allowlist (else 403); :token needs a Bearer
    #    token that config.authenticate turns into an identity (else 401 with
    #    a Bearer challenge). [:ip, :token] needs both, IP first.
    # 2. Answer from this disk; every response names this node. Request
    #    auth only: who may see which file is the app's business, on its own
    #    pages.
    # 3. Audit every answer (AuditLog), with the requester another node sent
    #    (trusted only once a check passed; unverified under :none).
    class BlobsController < ActionController::API
      include ActionController::HttpAuthentication::Token::ControllerMethods

      REALM = "Multi-node disk"
      BEARER = /\ABearer\s+\S/

      before_action :name_this_node
      before_action :authenticate_caller!
      before_action :set_blob

      # GET (the file) and HEAD (whether it is here).
      def show
        return not_here unless service&.local?(key)
        return answer { head :ok } if request.head?

        bytes = File.binread(service.path_for(key))
        answer { send_data bytes, filename: @blob&.filename.to_s.presence || key, type: "application/octet-stream" }
      rescue Errno::ENOENT, ActiveStorage::InvalidKeyError
        not_here
      end

      def destroy
        return not_here unless service

        begin
          File.delete(service.path_for(key))
        rescue Errno::ENOENT
          # Not here, or already deleted: nothing left on this node.
        end
        answer { head :no_content }
      rescue ActiveStorage::InvalidKeyError
        not_here
      end

      private

      def key = params[:key].to_s

      def name_this_node
        @started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        response.headers[NODE_HEADER] = this_node
      end

      def auth_modes
        @auth_modes ||= endpoint_service&.auth_modes || MultiNodeDisk::Configuration.auth_modes(MultiNodeDisk.config.auth)
      end

      def authenticate_caller!
        modes = auth_modes
        return deny(:forbidden) if modes.include?(:ip) && !allowed_ip?
        return @checked = modes != [:none] unless modes.include?(:token)

        if BEARER.match?(request.authorization.to_s)
          @identity = authenticate_with_http_token { |token, _options| MultiNodeDisk.config.authenticate.call(token, request) }
        end
        return @checked = true if @identity

        response.headers["WWW-Authenticate"] = %(Bearer realm="#{REALM}")
        deny(:unauthorized)
      end

      # The socket's peer. Only when that peer is one of the proxies the app
      # names in config.action_dispatch.trusted_proxies does request.remote_ip
      # (X-Forwarded-For) count: Rails' own remote_ip would otherwise take a
      # forwarded address any caller can write.
      def allowed_ip?
        caller_ip = IPAddr.new(caller_address.to_s)
        caller_ip = caller_ip.native if caller_ip.ipv4_mapped?
        endpoint_service.allowed_ips.any? { |allowed| allowed.include?(caller_ip) }
      rescue IPAddr::Error
        false
      end

      def caller_address
        proxies = Rails.application.config.action_dispatch.trusted_proxies
        peer = request.remote_addr.to_s
        return peer if proxies.blank?

        (Array(proxies).any? { |proxy| IPAddr.new(proxy.to_s).include?(peer) }) ? request.remote_ip : peer
      rescue IPAddr::Error
        peer
      end

      def set_blob
        @blob = ActiveStorage::Blob.find_by(key: key)
      end

      def action = request.delete? ? :delete : :read

      def audit_action
        return :delete if request.delete?

        request.head? ? :head : :read
      end

      # This node's MultiNodeDisk service (an in-process test may name
      # another); nil for a blob of a different service.
      def service
        return @service if defined?(@service)

        found = endpoint_service
        @service = found if found && (@blob.nil? || @blob.service_name == found.name.to_s)
      end

      def endpoint_service
        found = request.env[SERVICE_ENV_KEY] || MultiNodeDisk.service
        found if found.is_a?(ActiveStorage::Service::MultiNodeDiskService)
      end

      def this_node
        endpoint_service&.node || MultiNodeDisk.config.resolve(:current_node).to_s
      end

      def not_here
        answer(:not_found) { render json: {message: "not here", node: this_node}, status: :not_found }
      end

      def answer(result = nil)
        yield
        response.headers[NODE_HEADER] = this_node
        MultiNodeDisk.instrument(:serve, key: key, node: this_node, action: action, identity: @identity, status: response.status)
        audit(result || (request.delete? ? :deleted : :served))
      end

      def deny(status)
        MultiNodeDisk.instrument(:denied, key: key, node: this_node, action: action, status: Rack::Utils.status_code(status))
        head status
        audit(status)
      end

      def audit(result)
        hop = request.headers[MultiNodeDisk.config.hop_header].presence
        sent = MultiNodeDisk::Requester.decode(request.headers[MultiNodeDisk.config.requester_header])
        trusted = @checked == true
        entry = {
          action: audit_action, result: result, status: response.status, key: key,
          filename: @blob&.filename&.to_s, byte_size: @blob&.byte_size,
          node: this_node, from_node: hop, remote_ip: caller_address, auth: auth_modes,
          identity: @identity&.to_s, hop: !hop.nil?, duration_ms: duration_ms,
          requester_verified: (trusted if sent)
        }
        MultiNodeDisk::AuditLog.record(entry, request: request, requester: sent || MultiNodeDisk.current_requester)
      end

      def duration_ms
        ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - (@started || 0)) * 1000).round(1)
      end
    end
  end
end
