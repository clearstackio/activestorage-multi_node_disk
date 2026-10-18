# frozen_string_literal: true

module ActiveStorage
  module MultiNodeDisk
    # What an http_client returns: the status, the body and the headers
    # (names in any case).
    Response = Struct.new(:status, :body, :headers) do
      # @param name [String]
      # @return [String, nil]
      def header(name)
        wanted = name.downcase
        Array((headers || {}).find { |key, _| key.to_s.downcase == wanted }&.last).first
      end
    end
  end
end
