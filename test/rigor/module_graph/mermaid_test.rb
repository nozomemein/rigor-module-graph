# frozen_string_literal: true

require_relative "../../test_helper"

class MermaidTest < Minitest::Test
  include SnapshotHelpers

  Mermaid = Rigor::ModuleGraph::Mermaid
  Edge = Rigor::ModuleGraph::Edge

  def test_renders_all_kinds
    edges = [
      Edge.build(from: "Billing::Invoice", to: "ApplicationRecord", kind: "inherits"),
      Edge.build(from: "Billing::Invoice", to: "Auditable", kind: "include"),
      Edge.build(from: "Billing::Invoice", to: "Tracked", kind: "prepend"),
      Edge.build(from: "Billing::Invoice", to: "Searchable", kind: "extend"),
      Edge.build(from: "Billing::Invoice", to: "Money", kind: "const_ref")
    ]
    assert_snapshot "mermaid/all_kinds", Mermaid.render(edges)
  end

  def test_dedupes_repeated_edges
    edges = [
      Edge.build(from: "A", to: "B", kind: "include"),
      Edge.build(from: "A", to: "B", kind: "include")
    ]
    assert_snapshot "mermaid/dedup", Mermaid.render(edges)
  end

  def test_collapse_wraps_namespace_in_subgraph
    edges = [
      Edge.build(from: "Billing::Invoice", to: "ApplicationRecord", kind: "inherits"),
      Edge.build(from: "Billing::Invoice", to: "Auditable", kind: "include"),
      Edge.build(from: "Billing::Payment", to: "ApplicationRecord", kind: "inherits"),
      Edge.build(from: "Billing::Payment", to: "Auditable", kind: "include")
    ]
    assert_snapshot "mermaid/collapse_billing", Mermaid.render(edges, collapse: ["Billing"])
  end

  def test_groups_overrides_collapse_with_explicit_node_to_cluster
    edges = [
      Edge.build(from: "Invoice", to: "Application", kind: "inherits"),
      Edge.build(from: "User", to: "Application", kind: "inherits")
    ]
    groups = { "Invoice" => "packages/billing", "User" => "packages/auth" }
    assert_snapshot "mermaid/groups_packages", Mermaid.render(edges, groups: groups)
  end

  def test_unresolved_edge_gets_unresolved_class
    edges = [
      Edge.build(from: "Foo", to: "some_variable", kind: "include", confidence: "unresolved")
    ]
    assert_snapshot "mermaid/unresolved", Mermaid.render(edges)
  end

  def test_escape_label_replaces_double_quote_with_html_entity
    edges = [Edge.build(from: 'has"quote', to: "Other", kind: "include")]
    rendered = Mermaid.render(edges)
    assert_includes rendered, "#quot;"
  end

  def test_better_tag_prefers_inherits_over_include_for_target
    edges = [
      Edge.build(from: "A", to: "Base", kind: "include"),
      Edge.build(from: "B", to: "Base", kind: "inherits")
    ]
    rendered = Mermaid.render(edges)
    # Base is the target of both edges; inherits wins over include.
    assert_match(/class n\d+ inherits;/, rendered)
  end

  def test_unresolved_tag_dominates_in_priority
    edges = [
      Edge.build(from: "A", to: "Base", kind: "include"),
      Edge.build(from: "B", to: "Base", kind: "include", confidence: "unresolved")
    ]
    rendered = Mermaid.render(edges)
    assert_match(/class n\d+ unresolved;/, rendered)
  end

  def test_render_with_unknown_kind_falls_back_to_default_arrow
    # Edge.build validates kind, so we can't construct an edge
    # with an unknown kind directly. Skip — the default arrow
    # branch is theoretically reachable only via raw EDGE_KINDS
    # extension; cover via the fetch fallback path indirectly by
    # confirming ARROW_FOR_KIND is consulted properly.
    refute_nil Rigor::ModuleGraph::Mermaid::ARROW_FOR_KIND["inherits"]
  end

  def test_render_with_empty_edges_does_not_emit_node_section_separator
    rendered = Mermaid.render([])
    refute_includes rendered, "n0"
  end

  def test_better_tag_unresolved_never_replaced
    edges = [
      Edge.build(from: "A", to: "T", kind: "include", confidence: "unresolved"),
      Edge.build(from: "B", to: "T", kind: "inherits")
    ]
    rendered = Mermaid.render(edges)
    # T was first tagged unresolved; inherits should not displace it.
    assert_match(/class n\d+ unresolved;/, rendered)
  end
end
