# frozen_string_literal: true

module ActiveStorage
  module MultiNodeDisk
    # One audit entry per request the endpoint answered (served, refused or
    # deleted) and per remote fetch or delete this node made, as one JSON
    # document (schema VERSION) to the configured sink:
    #
    # - :file (default): a JSON line appended to config.audit_path;
    # - :table: an Audit row (after the host ran the generator's migration);
    # - :none: nothing; or any callable, given the entry.
    #
    # The same entry is instrumented as `audit.multi_node_disk`. It never
    # holds a token, file contents or a signed URL. A sink that fails is
    # logged and never fails the request.
    module AuditLog
      VERSION = 1

      # @param entry [Hash] action, result, status, key and the rest
      # @param request [ActionDispatch::Request, nil] the request answered, if any
      # @param requester [Hash, nil] who the request is for (else the current one)
      # @return [Hash] the entry written
      def self.record(entry, request: nil, requester: MultiNodeDisk.current_requester)
        config = MultiNodeDisk.config
        document = {v: VERSION, at: Time.now.utc.iso8601(3)}.merge(entry)
        document[:requester] = requester || config.audit_requester&.call(request)
        document[:context] = config.audit_context&.call(request, document)
        document = document.compact.as_json

        MultiNodeDisk.instrument(:audit, document)
        write(config.audit, document)
        document
      end

      def self.write(sink, document)
        case sink.to_s
        when "none" then nil
        when "file" then FileSink.instance.write(MultiNodeDisk.config.audit_path, document)
        when "table" then Audit.create!(payload: document)
        else sink.call(document)
        end
      rescue => error
        Rails.logger&.error("[ActiveStorage::MultiNodeDisk] audit not written (#{error.class}: #{error.message})")
      end
      private_class_method :write
    end
  end
end
