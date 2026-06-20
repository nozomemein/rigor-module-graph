# frozen_string_literal: true

require_relative "../../test_helper"

class CycleDetectorTest < Minitest::Test
  CycleDetector = Rigor::ModuleGraph::CycleDetector
  Edge = Rigor::ModuleGraph::Edge

  def edge(from, to, kind = "include")
    Edge.build(from: from, to: to, kind: kind)
  end

  def test_no_cycles_returns_empty
    edges = [edge("A", "B"), edge("B", "C")]
    assert_empty CycleDetector.detect(edges)
  end

  def test_simple_cycle
    edges = [edge("A", "B"), edge("B", "A")]
    cycles = CycleDetector.detect(edges)
    assert_equal 1, cycles.size
    assert_equal %w[A B], cycles.first.nodes
  end

  def test_three_node_cycle_starts_at_smallest_name
    edges = [edge("C", "A"), edge("A", "B"), edge("B", "C")]
    cycles = CycleDetector.detect(edges)
    assert_equal 1, cycles.size
    assert_equal %w[A B C], cycles.first.nodes
  end

  def test_self_loop
    edges = [edge("A", "A")]
    cycles = CycleDetector.detect(edges)
    assert_equal 1, cycles.size
    assert_equal ["A"], cycles.first.nodes
  end

  def test_kinds_filter_excludes_non_matching_edges
    edges = [
      edge("A", "B", "include"),
      edge("B", "A", "const_ref")
    ]
    assert_empty CycleDetector.detect(edges, kinds: %w[include])
  end

  def test_disjoint_cycles_each_reported
    edges = [
      edge("A", "B"), edge("B", "A"),
      edge("C", "D"), edge("D", "C")
    ]
    cycles = CycleDetector.detect(edges)
    assert_equal 2, cycles.size
    assert_equal %w[A B], cycles[0].nodes
    assert_equal %w[C D], cycles[1].nodes
  end

  def test_cycle_to_s_renders_round_trip
    cycle = CycleDetector::Cycle.new(nodes: %w[A B C])
    assert_equal "A -> B -> C -> A", cycle.to_s
  end

  def test_self_loop_collected
    edges = [edge("A", "A")]
    cycles = CycleDetector.detect(edges)
    assert_equal 1, cycles.size
    assert_equal ["A"], cycles.first.nodes
  end

  def test_walk_cycle_handles_complex_scc
    # SCC of 4 nodes with cross edges; should produce smallest-first rotation.
    edges = [
      edge("D", "C"), edge("C", "B"), edge("B", "A"), edge("A", "D"),
      edge("B", "D"), edge("C", "A")
    ]
    cycles = CycleDetector.detect(edges)
    assert_equal 1, cycles.size
    assert_equal "A", cycles.first.nodes.first
    assert_equal 4, cycles.first.nodes.size
  end
end
