# frozen_string_literal: true

module ActiveStorage
  module MultiNodeDisk
    # What every file error carries, for triage: the nodes involved, the
    # blob key and the file name.
    module FileError
      # @return [Array<String>]
      attr_reader :nodes
      # @return [String, nil]
      attr_reader :key, :filename

      # @param nodes [Array<String>, String, nil]
      # @param key [String, nil]
      # @param filename [String, nil]
      # @param reason [String, nil] what the transport or the nodes said
      def initialize(nodes: nil, key: nil, filename: nil, reason: nil)
        @nodes = Array(nodes).map(&:to_s)
        @key = key
        @filename = filename&.to_s
        super([describe, reason].compact.join(": "))
      end

      # @return [String] the nodes, for messages ("node-b and node-c")
      def node
        nodes.to_sentence.presence || "any node"
      end

      private

      def file_label
        filename.presence || key
      end
    end
  end
end
