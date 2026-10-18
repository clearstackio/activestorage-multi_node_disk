# frozen_string_literal: true

require "fileutils"
require "json"

module ActiveStorage
  module MultiNodeDisk
    # The default audit sink: one JSON document per line, appended. A lock
    # keeps this process's threads apart and flock keeps processes apart, so
    # lines never interleave. Rotation is the host's (logrotate with
    # copytruncate, or rename the file: the next write opens a new one).
    class FileSink
      # @return [FileSink] the process's sink
      def self.instance
        @instance ||= new
      end

      def initialize
        @lock = Mutex.new
      end

      # @param path [String, Pathname]
      # @param document [Hash]
      def write(path, document)
        line = "#{JSON.generate(document)}\n"
        @lock.synchronize do
          FileUtils.mkdir_p(File.dirname(path))
          File.open(path, File::WRONLY | File::APPEND | File::CREAT, 0o640) do |file|
            file.flock(File::LOCK_EX)
            file.write(line)
          ensure
            file.flock(File::LOCK_UN)
          end
        end
      end
    end
  end
end
