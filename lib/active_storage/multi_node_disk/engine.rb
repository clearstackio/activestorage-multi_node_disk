# frozen_string_literal: true

module ActiveStorage
  module MultiNodeDisk
    # The endpoint other nodes call, isolated from the app: its controller,
    # its routes and their helpers stay in this namespace. Mounted under
    # Active Storage's own prefix (mount_path, by default
    # /rails/active_storage/multi_node_disk), ahead of the app's routes so a
    # catch-all cannot hide it; nothing is drawn at the app's root.
    class Engine < ::Rails::Engine
      isolate_namespace ActiveStorage::MultiNodeDisk

      initializer "active_storage_multi_node_disk.routes" do |app|
        app.routes.prepend do
          if ActiveStorage::MultiNodeDisk.config.draw_routes
            mount ActiveStorage::MultiNodeDisk::Engine => ActiveStorage::MultiNodeDisk.mount_path, :as => :active_storage_multi_node_disk
          end
        end
      end

      config.after_initialize { MultiNodeDisk.finalize! }
    end
  end
end
