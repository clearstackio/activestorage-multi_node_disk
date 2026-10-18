# frozen_string_literal: true

module ActiveStorage
  module MultiNodeDisk
    # Some node that may hold the file did not answer as itself: a
    # connection error, a timeout, a 5xx, a refusal, or another node
    # answering in its place. Worth retrying.
    class Unavailable < ActiveStorage::Error
      include FileError

      private

      def describe = "#{node} is not answering"
    end
  end
end
