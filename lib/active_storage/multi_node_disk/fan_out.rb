# frozen_string_literal: true

module ActiveStorage
  module MultiNodeDisk
    # Runs calls in parallel threads (at most MAX_THREADS at a time) under
    # one deadline, and stops once the block says a result wins.
    #
    # 1. Each call runs in its own thread, inside the Rails executor. Calls
    #    get everything from the caller: they must not touch the database or
    #    host hooks, and a transport must be safe to call from several
    #    threads at once.
    # 2. Results arrive as calls finish; the block sees each one, on the
    #    caller's thread.
    # 3. The deadline starts here and covers the wait and the block; no call
    #    starts after it. When it passes, or the block answers true, calls
    #    still running are killed and joined within one shared JOIN_SECONDS
    #    budget: their ensure blocks close what they opened; a thread still
    #    alive after that is left to finish (it is already killed), and a
    #    socket caught mid-connect is closed when it is collected.
    # 4. Calls that never started (more nodes than threads, deadline gone)
    #    have no result: the caller counts them as failed.
    module FanOut
      MAX_THREADS = 8
      JOIN_SECONDS = 1

      # @param calls [Hash{String => #call}] by node
      # @param deadline [Numeric] seconds for the whole run
      # @yieldparam node [String]
      # @yieldparam result [Object, Exception] the call's value, or what it raised
      # @yieldreturn [Boolean] true to stop
      # @return [Hash{String => Object}] the results that arrived, by node
      def self.run(calls, deadline:)
        results = {}
        pending = calls.to_a
        running = {}
        finished = Thread::Queue.new
        stop_at = now + deadline

        loop do
          while running.size < MAX_THREADS && now < stop_at && (job = pending.shift)
            running[job.first] = start(*job, finished)
          end
          break if running.empty?

          remaining = stop_at - now
          break unless remaining.positive? && (item = finished.pop(timeout: remaining))

          node, result = item
          running.delete(node)
          results[node] = result
          break if yield(node, result)
        end
        results
      ensure
        running&.each_value(&:kill)
        cleanup_by = now + JOIN_SECONDS
        running&.each_value { |thread| thread.join([cleanup_by - now, 0].max) }
      end

      def self.now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      def self.start(node, call, finished)
        Thread.new do
          Thread.current.report_on_exception = false
          result = begin
            Rails.application.executor.wrap { call.call }
          rescue => error
            error
          end
          finished << [node, result]
        end
      end
      private_class_method :now, :start
    end
  end
end
