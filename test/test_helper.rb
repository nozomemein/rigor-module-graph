# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

# C2 (branch) coverage. Toggle on with `COVERAGE=1 rake test`;
# the report writes to `coverage/`. Loading SimpleCov MUST happen
# before any `require_relative "../lib"` so every branch entry
# point is recorded; that's also why we configure it before
# `require "rigor-module-graph"` further down the file.
if ENV["COVERAGE"]
  require "simplecov"
  SimpleCov.start do
    enable_coverage :branch
    primary_coverage :branch
    minimum_coverage_by_file branch: 0
    add_filter "/test/"
    add_filter "/examples/"
    add_filter "/templates/"
    add_filter "/vendor/"
    track_files "lib/**/*.rb"
  end
end

require "minitest/autorun"
require "minitest/snapshot"

require "rigor-module-graph"

# The Analyzer consults `::Rigor::Type::Singleton` to promote
# indirect mixin references — but the rigortype constants are
# only loaded when the plugin runs inside `rigor check`. Stand
# in a tiny shim here so the resolve_via_scope branch is
# exercisable in unit tests.
unless defined?(Rigor::Type::Singleton)
  module Rigor
    module Type
      Singleton = Struct.new(:class_name)
    end
  end
end

Minitest::Snapshot.configure do |config|
  config.snapshot_dir = File.expand_path("snapshots", __dir__)
end

module SnapshotHelpers
  include Minitest::Snapshot
end

# Tiny Prism walking helper for tests that exercise rules taking a
# NodeContext. We don't load rigortype in unit tests (it has heavy
# RBS startup), so we inline the minimum we need from
# `Rigor::Source::NodeWalker.each_with_ancestors`.
module PrismAncestors
  def self.each_node(source, &block)
    require "prism"
    root = Prism.parse(source).value
    walk(root, [], &block)
  end

  def self.walk(node, ancestors, &block)
    return unless node.is_a?(Prism::Node)

    block.call(node, ancestors)
    ancestors.push(node)
    node.compact_child_nodes.each { |child| walk(child, ancestors, &block) }
    ancestors.pop
  end
end

# Minimal stand-in for Rigor::Plugin::NodeContext so unit tests for
# Analyzer don't need to boot rigortype. Mirrors the real API the
# Analyzer reads (`ancestors`, `enclosing_module`, `enclosing_def`).
class FakeNodeContext
  attr_reader :ancestors

  def initialize(ancestors)
    @ancestors = ancestors.dup.freeze
  end

  def enclosing_module
    @ancestors.rfind do |n|
      n.is_a?(Prism::ClassNode) || n.is_a?(Prism::ModuleNode)
    end
  end

  def enclosing_def
    @ancestors.rfind { |n| n.is_a?(Prism::DefNode) }
  end
end
