# frozen_string_literal: true

module ActiveStorage
  module MultiNodeDisk
    # The :table audit sink: one row per entry, the whole entry in payload
    # (JSON on PostgreSQL, a CLOB on Oracle). The table comes from the
    # host's migration (`bin/rails g active_storage:multi_node_disk:install
    # --audit`); the gem never creates it.
    class Audit < ActiveRecord::Base
      self.table_name = "#{MultiNodeDisk.config.table_name_prefix}audits"

      attribute :payload, :json
    end
  end
end
