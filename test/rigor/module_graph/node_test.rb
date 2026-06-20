# frozen_string_literal: true

require_relative "../../test_helper"
require "stringio"

class NodeTest < Minitest::Test
  Node = Rigor::ModuleGraph::Node
  NodeIO = Rigor::ModuleGraph::NodeIO

  def test_build_validates_kind
    assert_raises(ArgumentError) { Node.build(kind: "weird", name: "Foo") }
  end

  def test_build_validates_visibility
    assert_raises(ArgumentError) do
      Node.build(kind: "instance_method", name: "foo", owner: "Bar", visibility: "weird")
    end
  end

  def test_build_validates_access
    assert_raises(ArgumentError) do
      Node.build(kind: "attribute", name: "foo", owner: "Bar", access: "weird")
    end
  end

  def test_to_h_omits_nil_optionals
    node = Node.build(kind: "class", name: "Foo")
    assert_equal({ "kind" => "class", "name" => "Foo" }, node.to_h)
  end

  def test_dedup_key_collapses_method_redefinitions
    a = Node.build(kind: "instance_method", name: "save", owner: "Invoice", line: 1)
    b = Node.build(kind: "instance_method", name: "save", owner: "Invoice", line: 99)
    assert_equal a.dedup_key, b.dedup_key
  end

  def test_to_h_with_all_optional_fields_populated
    node = Node.build(
      kind: "instance_method", name: "save", owner: "Foo",
      path: "a.rb", line: 5, column: 3,
      visibility: "private"
    )
    h = node.to_h
    assert_equal "private", h["visibility"]
    assert_equal "Foo", h["owner"]
    assert_equal 5, h["line"]
  end

  def test_message_payload_excludes_position
    node = Node.build(
      kind: "instance_method", name: "save", owner: "Foo",
      path: "a.rb", line: 9, visibility: "public"
    )
    payload = node.to_message_payload
    refute_includes payload.keys, "path"
    refute_includes payload.keys, "line"
    assert_equal "public", payload["visibility"]
  end

  def test_attribute_includes_access_in_payload
    node = Node.build(
      kind: "attribute", name: "title", owner: "Foo",
      access: "accessor", visibility: "public"
    )
    payload = node.to_message_payload
    assert_equal "accessor", payload["access"]
  end

  def test_to_h_includes_all_attribute_fields
    node = Node.build(
      kind: "attribute", name: "title", owner: "Foo",
      access: "accessor", visibility: "public",
      path: "foo.rb", line: 5
    )
    h = node.to_h
    assert_equal "accessor", h["access"]
    assert_equal "public", h["visibility"]
    assert_equal "Foo", h["owner"]
  end

  def test_io_read_skips_blank_lines
    io = StringIO.new(<<~JSONL)
      {"kind":"class","name":"Foo"}

      {"kind":"module","name":"Bar"}
    JSONL
    nodes = NodeIO.read(io)
    assert_equal 2, nodes.size
  end

  def test_build_with_all_optional_args_nil
    node = Node.build(kind: "module", name: "Foo")
    assert_nil node.visibility
    assert_nil node.access
  end

  def test_io_round_trip_with_dedup
    nodes = [
      Node.build(kind: "class", name: "Invoice"),
      Node.build(kind: "class", name: "Invoice"), # dup
      Node.build(kind: "instance_method", name: "total", owner: "Invoice", visibility: "public")
    ]
    io = StringIO.new
    NodeIO.write(nodes, io)
    io.rewind
    read = NodeIO.read(io)
    assert_equal 2, read.size
    assert_equal "Invoice", read[0].name
    assert_equal "total", read[1].name
  end
end
