# frozen_string_literal: true

require "ipaddr"
require "resolv"

module ActiveStorage
  module MultiNodeDisk
    # The IP addresses of the nodes, for the endpoint's :ip check: resolved
    # by DNS (a node may also be written as an IP), kept for TTL seconds,
    # then resolved again. A node that fails to resolve keeps its last known
    # addresses. One lock guards the cache, so threads share it safely.
    class NodeAddresses
      TTL = 60

      Entry = Struct.new(:addresses, :expires_at)

      # @param resolver [#getaddresses] Resolv by default
      # @param clock [#call] monotonic seconds
      def initialize(resolver: Resolv, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @resolver = resolver
        @clock = clock
        @entries = {}
        @lock = Mutex.new
      end

      # @param nodes [Array<String>]
      # @return [Array<IPAddr>]
      def for(nodes)
        @lock.synchronize { nodes.flat_map { |node| entry_for(node).addresses } }
      end

      private

      def entry_for(node)
        now = @clock.call
        entry = @entries[node]
        return entry if entry && entry.expires_at > now

        @entries[node] = Entry.new(resolve(node) || entry&.addresses || [], now + TTL)
      end

      def resolve(node)
        found = @resolver.getaddresses(node).map { |address| IPAddr.new(address) }
        found.presence
      rescue Resolv::ResolvError, IPAddr::Error, SocketError
        nil
      end
    end
  end
end
