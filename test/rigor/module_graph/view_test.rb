# frozen_string_literal: true

require_relative "../../test_helper"
require "rigor/module_graph/cli"
require "stringio"

class ViewTest < Minitest::Test
  CLI = Rigor::ModuleGraph::CLI
  Edge = Rigor::ModuleGraph::Edge

  def test_effective_collapse_picks_namespaces_with_multiple_members
    edges = [
      Edge.build(from: "Billing::Invoice", to: "Auditable", kind: "include"),
      Edge.build(from: "Billing::Payment", to: "Auditable", kind: "include"),
      Edge.build(from: "Auth::User", to: "Concern", kind: "include"),
      Edge.build(from: "Toplevel", to: "ApplicationRecord", kind: "inherits")
    ]
    view = build_view
    # Billing has 2 members → collapsed. Auth has 1 → skipped.
    # Toplevel / ApplicationRecord / Concern / Auditable have no
    # `::` so they aren't collapse candidates.
    assert_equal ["Billing"], view.effective_collapse(edges)
  end

  def test_effective_collapse_respects_explicit_override
    view = build_view(collapse: ["Custom"])
    assert_equal ["Custom"], view.effective_collapse([])
  end

  def test_effective_collapse_respects_no_collapse
    view = build_view(collapse: [])
    edges = [
      Edge.build(from: "Billing::Invoice", to: "Auditable", kind: "include"),
      Edge.build(from: "Billing::Payment", to: "Auditable", kind: "include")
    ]
    assert_equal [], view.effective_collapse(edges)
  end

  def test_effective_collapse_does_not_pick_deep_prefixes
    # `Billing::Invoice::Line` and `Billing::Invoice::Item` would
    # be a candidate for the `Billing::Invoice` prefix, but we
    # only consider top-level prefixes so a graph stays readable.
    edges = [
      Edge.build(from: "Billing::Invoice::Line", to: "Auditable", kind: "include"),
      Edge.build(from: "Billing::Invoice::Item", to: "Auditable", kind: "include")
    ]
    view = build_view
    assert_equal ["Billing"], view.effective_collapse(edges)
  end

  def test_render_subtitle_includes_collapse_when_present
    view = build_view
    edges = [Edge.build(from: "A", to: "B", kind: "include")]
    subtitle = view.render_subtitle(edges, ["Billing"])
    assert_includes subtitle, "1 edge(s)"
    assert_includes subtitle, "collapsed: Billing"
  end

  def test_render_subtitle_omits_collapse_when_empty
    view = build_view
    subtitle = view.render_subtitle([], [])
    refute_includes subtitle, "collapsed:"
  end

  def build_view(collapse: nil)
    view = CLI::View.new(stdout: StringIO.new, stderr: StringIO.new)
    view.instance_variable_get(:@options)[:collapse] = collapse
    view
  end
end
