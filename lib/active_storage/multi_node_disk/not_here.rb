# frozen_string_literal: true

module ActiveStorage
  module MultiNodeDisk
    # No node has the file: this disk does not, and every other node
    # answered "not here" as itself. A FileNotFoundError, as Disk raises.
    class NotHere < ActiveStorage::FileNotFoundError
      include FileError

      private

      def describe = "#{file_label} is not on #{node}"
    end
  end
end
