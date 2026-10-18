# frozen_string_literal: true

module ActiveStorage
  module MultiNodeDisk
    # The other nodes' deletes, when config.delete_mode is :job (the local
    # copy is already gone). Idempotent: a node that answers 404 as itself
    # has nothing left. Retried while a node does not confirm; a host
    # changes the retries by subclassing (config.delete_job_class) and the
    # queue with config.delete_job_queue. Loaded only in :job mode, so
    # Active Job stays optional.
    class DeleteJob < ActiveJob::Base
      retry_on Unavailable, wait: :polynomially_longer, attempts: 10 do |job, error|
        MultiNodeDisk.instrument(:delete_abandoned, key: job.arguments.second, nodes: error.nodes)
      end

      # @param service_name [String] the MultiNodeDisk service in storage.yml
      # @param key [String]
      # @param nodes [Array<String>] the nodes still to confirm
      # @param requester [Hash, nil] who the delete was for (recorded again)
      def perform(service_name, key, nodes, requester = nil)
        service = ActiveStorage::Blob.services.fetch(service_name)
        failed = MultiNodeDisk.with_requester(requester) { service.delete_elsewhere(key, nodes: nodes) }
        raise Unavailable.new(nodes: failed, key: key, reason: "delete not confirmed") if failed.any?
      end
    end
  end
end
