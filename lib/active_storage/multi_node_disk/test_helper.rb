# frozen_string_literal: true

require "rack/mock"
require "tmpdir"
require "fileutils"

module ActiveStorage
  module MultiNodeDisk
    # Fake nodes for a host's specs: no network, the gem's real endpoint.
    #
    #   include ActiveStorage::MultiNodeDisk::TestHelper
    #
    #   node_b = multi_node_disk_node("node-b")
    #   multi_node_disk_move(blob, to: node_b)
    #   multi_node_disk_cluster("node-b" => node_b, "node-c" => :missing) do |requests|
    #     expect(blob.download).to eq(bytes)
    #   end
    module TestHelper
      # A node's answer when no service stands for it in the cluster.
      BEHAVIOURS = %i[missing timeout down wrong].freeze

      # Another node: a MultiNodeDiskService with its own disk root, named
      # like the app's service.
      #
      # @param node [String]
      # @param root [String]
      # @return [ActiveStorage::Service::MultiNodeDiskService]
      def multi_node_disk_node(node, root: Dir.mktmpdir("multi_node_disk-#{node}-"))
        here = MultiNodeDisk.service
        ActiveStorage::Service::MultiNodeDiskService.new(root: root, node: node, nodes: here.nodes).tap { |there| there.name = here.name }
      end

      # Moves a blob's file from this node's disk to another node's.
      #
      # @param blob [ActiveStorage::Blob]
      # @param to [ActiveStorage::Service::MultiNodeDiskService]
      def multi_node_disk_move(blob, to:)
        target = to.path_for(blob.key)
        FileUtils.mkdir_p(File.dirname(target))
        FileUtils.mv(blob.service.path_for(blob.key), target)
        to
      end

      # Runs the block with the other nodes answering in process: a service
      # through the gem's endpoint, :missing with a 404 as itself, :wrong
      # with bytes that are not the file, :timeout by never answering, :down
      # by refusing the connection; a node not listed is :down.
      #
      # @param nodes [Hash{String => ActiveStorage::Service::MultiNodeDiskService, Symbol}]
      # @param remote_addr [String] the caller's IP as the endpoint sees it
      # @yieldparam requests [Array<Hash>] method, node, url and header names (never values)
      def multi_node_disk_cluster(nodes = {}, remote_addr: "127.0.0.1", **named, &block)
        requests = []
        client = Cluster.new(nodes.merge(named.transform_keys(&:to_s)), remote_addr, requests)
        MultiNodeDisk.with_config(http_client: client) { block.call(requests) }
      end

      # The fake transport behind multi_node_disk_cluster.
      class Cluster
        def initialize(nodes, remote_addr, requests)
          @nodes = nodes
          @remote_addr = remote_addr
          @requests = requests
          @lock = Mutex.new
        end

        def call(method, url, headers:, node:, open_timeout:, read_timeout:)
          @lock.synchronize { @requests << {method: method, node: node, url: url, headers: headers.keys} }
          behaviour = @nodes.fetch(node, :down)
          case behaviour
          when :missing then Response.new(404, "", {NODE_HEADER => node})
          when :wrong then Response.new(200, "not the file", {NODE_HEADER => node})
          when :timeout then sleep
          when :down then raise Errno::ECONNREFUSED, node
          else serve(behaviour, method, url, headers)
          end
        end

        private

        def serve(service, method, url, headers)
          # The engine's own path: whatever precedes the mount (a public
          # prefix such as /app) is the host's proxy's business.
          path = URI(url).path.sub(/\A.*?#{Regexp.escape(MultiNodeDisk.mount_path)}/, "")
          env = Rack::MockRequest.env_for(path, :method => method.to_s.upcase, "REMOTE_ADDR" => @remote_addr)
          headers.each { |name, value| env["HTTP_#{name.upcase.tr("-", "_")}"] = value }
          env[SERVICE_ENV_KEY] = service
          status, response_headers, body = Engine.call(env)
          content = +""
          body.each { |part| content << part }
          body.close if body.respond_to?(:close)
          Response.new(status, content, response_headers.to_h)
        end
      end
    end
  end
end
