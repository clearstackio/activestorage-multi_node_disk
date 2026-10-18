# frozen_string_literal: true

module ActiveStorage
  module MultiNodeDisk
    # The bytes do not match the blob's size and checksum. An
    # IntegrityError, as Active Storage raises.
    class Mismatch < ActiveStorage::IntegrityError
      include FileError

      private

      def describe = "#{file_label}: the bytes do not match the stored file (#{node})"
    end
  end
end
