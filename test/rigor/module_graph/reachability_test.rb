# frozen_string_literal: true

require_relative "../../test_helper"

class ReachabilityTest < Minitest::Test
  Reachability = Rigor::ModuleGraph::Reachability
  Edge = Rigor::ModuleGraph::Edge

  def edge(from, to, kind = "include")
    Edge.build(from: from, to: to, kind: kind)
  end

  def test_empty_roots_returns_input_unchanged
    edges = [edge("A", "B")]
    assert_equal edges, Reachability.filter(edges, roots: [])
    assert_equal edges, Reachability.filter(edges, roots: nil)
  end

  def test_filter_with_root_keeps_only_reachable_edges
    edges = [
      edge("A", "B"),
      edge("B", "C"),
      edge("X", "Y") # unrelated
    ]
    filtered = Reachability.filter(edges, roots: ["A"])
    assert_equal 2, filtered.size
    refute_includes filtered.map(&:from), "X"
  end

  def test_depth_limits_hops
    edges = [
      edge("A", "B"),
      edge("B", "C"),
      edge("C", "D")
    ]
    filtered = Reachability.filter(edges, roots: ["A"], depth: 1)
    # depth 1: A → B reachable, C not yet.
    assert_equal([%w[A B]], filtered.map { |e| [e.from, e.to] })
  end

  def test_direction_out_only_follows_outgoing
    edges = [
      edge("A", "B"),
      edge("X", "A"), # incoming to A
      edge("B", "C")
    ]
    filtered = Reachability.filter(edges, roots: ["A"], direction: :out)
    # We start at A, only follow outgoing → reach B, C; skip X.
    assert_equal %w[B C].sort,
                 (filtered.flat_map { |e| [e.from, e.to] } - ["A"]).uniq.sort
  end

  def test_direction_in_follows_backwards
    edges = [
      edge("A", "B"),
      edge("X", "A"), # incoming to A
      edge("B", "C")
    ]
    filtered = Reachability.filter(edges, roots: ["A"], direction: :in)
    # Following inbound edges from A: X depends on A → X is reachable.
    # Not B (A → B is outbound for A).
    targets = filtered.map { |e| [e.from, e.to] }
    assert_equal [%w[X A]], targets
  end

  def test_direction_both_unions_in_and_out
    edges = [
      edge("A", "B"),
      edge("X", "A"),
      edge("B", "C")
    ]
    filtered = Reachability.filter(edges, roots: ["A"], direction: :both)
    pairs = filtered.map { |e| [e.from, e.to] }.sort
    assert_equal [%w[A B], %w[B C], %w[X A]].sort, pairs
  end

  def test_multiple_roots_union
    edges = [
      edge("A", "B"),
      edge("X", "Y"),
      edge("M", "N")
    ]
    filtered = Reachability.filter(edges, roots: %w[A X])
    pairs = filtered.map { |e| [e.from, e.to] }.sort
    assert_equal [%w[A B], %w[X Y]].sort, pairs
  end

  def test_unknown_direction_raises
    assert_raises(ArgumentError) do
      Reachability.filter([edge("A", "B")], roots: ["A"], direction: :sideways)
    end
  end

  def test_unknown_edge_scope_raises
    assert_raises(ArgumentError) do
      Reachability.filter([edge("A", "B")], roots: ["A"], edge_scope: :weird)
    end
  end

  # --- edge_scope: :walk ---

  def test_walk_scope_drops_internal_sibling_edges
    # Article -> ActsAsArticle, Article -> ApplicationRecord, plus
    # the sibling ActsAsArticle -> ApplicationRecord whose
    # endpoints both sit in the depth=1 reachable set. Cluster
    # keeps all three; walk keeps only the two BFS traverses.
    edges = [
      edge("Article", "ActsAsArticle", "include"),
      edge("Article", "ApplicationRecord", "inherits"),
      edge("ActsAsArticle", "ApplicationRecord", "inherits")
    ]
    cluster = Reachability.filter(edges, roots: ["Article"], depth: 1, direction: :out)
    assert_equal 3, cluster.size

    walk = Reachability.filter(edges, roots: ["Article"], depth: 1, direction: :out, edge_scope: :walk)
    assert_equal 2, walk.size
    walk.each { |e| assert_equal "Article", e.from }
  end

  def test_walk_scope_keeps_legitimate_two_hop_edges
    edges = [
      edge("A", "B"),
      edge("B", "C"),
      edge("D", "C")
    ]
    walk = Reachability.filter(edges, roots: ["A"], depth: 2, direction: :out, edge_scope: :walk)
    pairs = walk.map { |e| [e.from, e.to] }.sort
    assert_equal [%w[A B], %w[B C]], pairs
    refute_includes pairs, %w[D C]
  end

  def test_walk_scope_both_unions_in_and_out_walks_but_avoids_zigzag
    # forward A -> B and inbound C -> A. The (X -> Y)-style zigzag
    # that a forward+backward-mixed BFS would admit is X -> Z via
    # B's inbound. The walk-union semantics must not pick it up.
    edges = [
      edge("A", "B"),
      edge("C", "A"),
      edge("X", "B"),
      edge("X", "Z")
    ]
    walk = Reachability.filter(edges, roots: ["A"], depth: 2, direction: :both, edge_scope: :walk)
    pairs = walk.map { |e| [e.from, e.to] }.sort
    # X -> B picked up by inbound walk reaching X via B; but X -> Z
    # is *not* on any out-walk-or-in-walk from A.
    assert_includes pairs, %w[A B]
    assert_includes pairs, %w[C A]
    refute_includes pairs, %w[X Z]
  end

  def test_walk_scope_falls_back_to_cluster_when_roots_empty
    edges = [edge("A", "B"), edge("X", "Y")]
    # Empty roots short-circuit before scope dispatch, so both
    # scopes match (edges returned unchanged).
    assert_equal edges, Reachability.filter(edges, roots: [], edge_scope: :walk)
  end

  def test_walk_scope_with_unlimited_depth
    edges = [edge("A", "B"), edge("B", "C"), edge("C", "D")]
    walk = Reachability.filter(edges, roots: ["A"], direction: :out, edge_scope: :walk)
    pairs = walk.map { |e| [e.from, e.to] }
    assert_equal [%w[A B], %w[B C], %w[C D]], pairs
  end

  def test_walk_scope_in_direction
    edges = [edge("A", "B"), edge("B", "C"), edge("X", "A")]
    walk = Reachability.filter(edges, roots: ["A"], depth: 2, direction: :in, edge_scope: :walk)
    pairs = walk.map { |e| [e.from, e.to] }
    assert_includes pairs, %w[X A]
  end

  def test_walk_revisits_existing_neighbour_skips_addition
    edges = [
      edge("A", "B"),
      edge("A", "B"), # duplicate target — should not be re-added
      edge("B", "C")
    ]
    walk = Reachability.filter(edges, roots: ["A"], direction: :out, edge_scope: :walk)
    refute_empty walk
  end
end
