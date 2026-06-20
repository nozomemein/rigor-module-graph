# frozen_string_literal: true

require "stringio"
require_relative "../../test_helper"

class StatusReporterTest < Minitest::Test
  def test_non_tty_emits_step_start_and_done_on_separate_lines
    err = StringIO.new
    reporter = Rigor::ModuleGraph::StatusReporter.new(stderr: err)

    result = reporter.step("Doing thing") { 42 }

    assert_equal 42, result
    lines = err.string.lines.map(&:chomp)
    assert_equal "==> Doing thing", lines[0]
    assert_match(/\A    done \(\d+(ms|\.\d+s)\)\z/, lines[1])
  end

  def test_tty_emits_step_start_and_done_inline
    err = TtyStringIO.new
    reporter = Rigor::ModuleGraph::StatusReporter.new(stderr: err)

    reporter.step("Doing thing") { :ok }

    # "==> Doing thing... " (no newline) then "done (Xms)\n"
    assert_match(/\A==> Doing thing\.\.\. done \(\d+(ms|\.\d+s)\)\n\z/, err.string)
  end

  def test_step_reraises_after_printing_failed_tail
    err = StringIO.new
    reporter = Rigor::ModuleGraph::StatusReporter.new(stderr: err)
    boom = Class.new(StandardError)

    assert_raises(boom) do
      reporter.step("Risky") { raise boom, "x" }
    end

    assert_match(/failed \(\d+(ms|\.\d+s)\)/, err.string)
  end

  def test_info_indents_under_the_most_recent_step
    err = StringIO.new
    reporter = Rigor::ModuleGraph::StatusReporter.new(stderr: err)

    reporter.step("Counting") { :ok }
    reporter.info "10 widgets, 3 sprockets"

    last_line = err.string.lines.last.chomp
    assert_equal "    10 widgets, 3 sprockets", last_line
  end

  def test_quiet_suppresses_step_and_info_but_keeps_block_return
    err = StringIO.new
    reporter = Rigor::ModuleGraph::StatusReporter.new(stderr: err, quiet: true)

    result = reporter.step("Quiet step") { 99 }
    reporter.info "should not appear"

    assert_equal 99, result
    assert_empty err.string
  end

  def test_quiet_lets_exceptions_propagate_without_printing
    err = StringIO.new
    reporter = Rigor::ModuleGraph::StatusReporter.new(stderr: err, quiet: true)

    assert_raises(RuntimeError) do
      reporter.step("noisy") { raise "boom" }
    end

    assert_empty err.string
  end

  # StringIO doesn't have `tty?` returning true; this minimal
  # wrapper opts in so the inline-rendering branch of
  # StatusReporter is reachable from tests without a real PTY.
  class TtyStringIO < StringIO
    def tty?
      true
    end
  end
end
