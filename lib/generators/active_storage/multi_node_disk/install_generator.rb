# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module ActiveStorage
  module MultiNodeDisk
    # `bin/rails g active_storage:multi_node_disk:install [--audit]`: the
    # initializer, and with --audit the host's migration for the audit
    # table (as Blazer's install generator writes its own). Nothing here runs
    # a migration.
    class InstallGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.join(__dir__, "templates")

      class_option :audit, type: :boolean, default: false, desc: "Add the migration for the :table audit sink"

      # @return [void]
      def copy_initializer
        template "initializer.rb", "config/initializers/active_storage_multi_node_disk.rb"
      end

      # @return [void]
      def copy_audit_migration
        return unless options[:audit]

        migration_template "create_audits.rb", "db/migrate/create_active_storage_multi_node_disk_audits.rb", migration_version: migration_version
      end

      private

      def migration_version
        "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
      end

      def table_name
        "#{ActiveStorage::MultiNodeDisk.config.table_name_prefix}audits"
      end

      # Short and explicit: Oracle before 12.2 allows 30 characters.
      def index_name
        "i_#{ActiveStorage::MultiNodeDisk.config.table_name_prefix.split("_").map(&:first).join}_audits_created_at"
      end
    end
  end
end
