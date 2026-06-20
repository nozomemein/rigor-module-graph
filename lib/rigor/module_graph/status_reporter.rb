# frozen_string_literal: true

module Rigor
  module ModuleGraph
    # Step-level progress reporter that prints to stderr.
    #
    # On a TTY the message + elapsed time render inline on a
    # single line ("==> Running rigor check... done (4.32s)").
    # When stderr is redirected (CI logs, piping into another
    # command, `tee` to a file) both halves print on separate
    # lines so the output stays line-oriented and grep-friendly.
    #
    # `quiet: true` silences every method; callers can wire a
    # `--quiet` CLI flag through without litterring conditionals
    # at each call site.
    #
    # Usage:
    #
    #   status = StatusReporter.new(stderr: $stderr)
    #   edges = status.step("Running rigor check") do
    #     runner.edges_for(paths)
    #   end
    #   status.info "#{edges.size} edges"
    class StatusReporter
      def initialize(stderr:, quiet: false)
        @stderr = stderr
        @quiet = quiet
        @tty = stderr.respond_to?(:tty?) && stderr.tty?
      end

      # Print a "==> message..." line, yield, then print the
      # outcome ("done (Xms)" or "failed") with elapsed time.
      # Returns whatever the block returns; re-raises on
      # exception after printing the failure tail so callers can
      # still rescue normally.
      def step(message)
        return yield if @quiet

        start_step(message)
        started_at = monotonic
        begin
          result = yield
        rescue StandardError
          finish_step("failed", monotonic - started_at)
          raise
        end
        finish_step("done", monotonic - started_at)
        result
      end

      # Print an informational line indented under the most
      # recent step. Used for "2016 edges, 87 nodes" style
      # post-step counts.
      def info(message)
        return if @quiet

        @stderr.puts "    #{message}"
      end

      private

      def start_step(message)
        prefix = "==> #{message}"
        if @tty
          @stderr.print "#{prefix}... "
          @stderr.flush
        else
          @stderr.puts prefix
        end
      end

      def finish_step(verb, elapsed)
        duration = format_duration(elapsed)
        if @tty
          @stderr.puts "#{verb} #{duration}"
        else
          @stderr.puts "    #{verb} #{duration}"
        end
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def format_duration(seconds)
        if seconds < 1
          "(#{(seconds * 1000).round}ms)"
        else
          "(#{seconds.round(2)}s)"
        end
      end
    end
  end
end
