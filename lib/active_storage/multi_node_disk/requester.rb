# frozen_string_literal: true

module ActiveStorage
  module MultiNodeDisk
    # Who a file operation is for, set around work that serves no request
    # (a job): `ActiveStorage::MultiNodeDisk.with_requester(...) { blob.open { } }`.
    # Kept per thread or fiber (Rails' isolation level), so concurrent work
    # never shares it. The gem records and forwards it; it never reads it.
    module Requester
      KEY = :active_storage_multi_node_disk_requester
      # Largest requester header sent or read, in bytes.
      MAX_BYTES = 1024

      # @return [Hash, nil]
      def self.current
        ActiveSupport::IsolatedExecutionState[KEY]
      end

      # @param requester [Hash, nil]
      def self.with(requester)
        previous = current
        ActiveSupport::IsolatedExecutionState[KEY] = requester
        yield
      ensure
        ActiveSupport::IsolatedExecutionState[KEY] = previous
      end

      # @param requester [Hash, nil]
      # @return [String, nil] JSON for the header; nil when absent or too large
      def self.encode(requester)
        return if requester.nil?

        json = JSON.generate(requester.as_json)
        json if json.bytesize <= MAX_BYTES
      end

      # @param header [String, nil]
      # @return [Hash, nil] the requester another node sent; nil when absent,
      #   too large or not a JSON object
      def self.decode(header)
        return if header.blank? || header.bytesize > MAX_BYTES

        found = JSON.parse(header)
        found if found.is_a?(Hash)
      rescue JSON::ParserError
        nil
      end
    end
  end
end
