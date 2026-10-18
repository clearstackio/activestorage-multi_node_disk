# frozen_string_literal: true

require "net/http"
require "uri"

module ActiveStorage
  module MultiNodeDisk
    # The default transport: Net::HTTP, as Active Storage's own services
    # use, with the system resolver. HTTPS verifies the certificate.
    class NetHttpClient
      METHODS = {get: Net::HTTP::Get, head: Net::HTTP::Head, delete: Net::HTTP::Delete}.freeze

      # @param method [Symbol] :get, :head or :delete
      # @param url [String]
      # @param headers [Hash{String => String}]
      # @param node [String] the node addressed (unused: the URL names it; a host client may pin to it)
      # @param open_timeout [Numeric]
      # @param read_timeout [Numeric]
      # @return [Response]
      def call(method, url, headers:, node:, open_timeout:, read_timeout:)
        uri = URI(url)
        request = METHODS.fetch(method).new(uri)
        headers.each { |name, value| request[name] = value }
        answer = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: open_timeout, read_timeout: read_timeout) do |http|
          http.request(request)
        end
        Response.new(answer.code.to_i, answer.body.to_s, answer.each_header.to_h)
      end
    end
  end
end
