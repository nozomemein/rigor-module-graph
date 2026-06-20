# frozen_string_literal: true

require_relative "../../test_helper"

class ClassDiagramTest < Minitest::Test
  include SnapshotHelpers

  ClassDiagram = Rigor::ModuleGraph::Uml::ClassDiagram
  Edge = Rigor::ModuleGraph::Edge
  Node = Rigor::ModuleGraph::Node

  def test_minimal_class_diagram
    edges = [
      Edge.build(from: "Billing::Invoice", to: "ApplicationRecord", kind: "inherits"),
      Edge.build(from: "Billing::Invoice", to: "Auditable", kind: "include")
    ]
    nodes = [
      Node.build(kind: "class", name: "Billing::Invoice"),
      Node.build(kind: "module", name: "Auditable")
    ]
    assert_snapshot "class_diagram/minimal", ClassDiagram.render(edges, nodes)
  end

  def test_with_methods_and_attributes
    edges = [Edge.build(from: "Invoice", to: "ApplicationRecord", kind: "inherits")]
    nodes = [
      Node.build(kind: "class", name: "Invoice"),
      Node.build(kind: "instance_method", name: "total", owner: "Invoice", visibility: "public"),
      Node.build(kind: "instance_method", name: "save_silently", owner: "Invoice", visibility: "private"),
      Node.build(kind: "class_method", name: "find", owner: "Invoice", visibility: "public"),
      Node.build(kind: "attribute", name: "amount", owner: "Invoice", visibility: "public", access: "accessor")
    ]
    assert_snapshot "class_diagram/with_members", ClassDiagram.render(edges, nodes)
  end

  def test_public_only_hides_private_methods
    nodes = [
      Node.build(kind: "class", name: "Invoice"),
      Node.build(kind: "instance_method", name: "total", owner: "Invoice", visibility: "public"),
      Node.build(kind: "instance_method", name: "secret", owner: "Invoice", visibility: "private")
    ]
    rendered = ClassDiagram.render([], nodes, visibilities: %w[public])
    assert_includes rendered, "total"
    refute_includes rendered, "secret"
  end

  def test_no_methods_keeps_class_shells_only
    nodes = [
      Node.build(kind: "class", name: "Invoice"),
      Node.build(kind: "instance_method", name: "total", owner: "Invoice", visibility: "public")
    ]
    rendered = ClassDiagram.render([], nodes, include_methods: false)
    refute_includes rendered, "total"
    assert_includes rendered, "class Invoice"
  end

  def test_has_many_renders_with_cardinality
    edges = [
      Edge.build(from: "User", to: "Invoice", kind: "has_many")
    ]
    nodes = [
      Node.build(kind: "class", name: "User"),
      Node.build(kind: "class", name: "Invoice")
    ]
    rendered = ClassDiagram.render(edges, nodes)
    assert_includes rendered, '"1"'
    assert_includes rendered, '"*"'
    assert_includes rendered, "has_many"
  end

  def test_namespaced_constant_uses_safe_id_with_label
    edges = [
      Edge.build(from: "Billing::Invoice", to: "ApplicationRecord", kind: "inherits")
    ]
    nodes = [Node.build(kind: "class", name: "Billing::Invoice")]
    rendered = ClassDiagram.render(edges, nodes)
    assert_includes rendered, "Billing__Invoice"
    assert_includes rendered, '["Billing::Invoice"]'
  end

  def test_module_node_carries_module_marker_in_label
    nodes = [Node.build(kind: "module", name: "Auditable")]
    rendered = ClassDiagram.render([], nodes)
    assert_includes rendered, "«module»"
  end

  def test_unknown_kind_falls_back_to_default_arrow
    edges = [Edge.build(from: "Foo", to: "Bar", kind: "const_ref")]
    rendered = ClassDiagram.render(edges, [])
    assert_includes rendered, "<.."
  end

  def test_class_diagram_with_empty_input
    rendered = ClassDiagram.render([], [])
    assert_includes rendered, "classDiagram"
  end
end
