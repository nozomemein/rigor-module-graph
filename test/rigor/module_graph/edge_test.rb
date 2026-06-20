# frozen_string_literal: true

require_relative "../../test_helper"
require "stringio"

class EdgeTest < Minitest::Test
  Edge = Rigor::ModuleGraph::Edge
  EdgeIO = Rigor::ModuleGraph::EdgeIO

  def test_build_validates_kind
    error = assert_raises(ArgumentError) do
      Edge.build(from: "A", to: "B", kind: "weird")
    end
    assert_includes error.message, "unknown edge kind"
  end

  def test_build_validates_confidence
    error = assert_raises(ArgumentError) do
      Edge.build(from: "A", to: "B", kind: "include", confidence: "weird")
    end
    assert_includes error.message, "unknown confidence"
  end

  def test_to_h_omits_nil_optionals
    edge = Edge.build(from: "A", to: "B", kind: "include")
    assert_equal(
      { "from" => "A", "to" => "B", "kind" => "include", "confidence" => "syntax" },
      edge.to_h
    )
  end

  def test_to_h_keeps_positional_metadata
    edge = Edge.build(from: "A", to: "B", kind: "include", path: "a.rb", line: 3, column: 5)
    assert_equal(
      {
        "from" => "A", "to" => "B", "kind" => "include",
        "path" => "a.rb", "line" => 3, "column" => 5, "confidence" => "syntax"
      },
      edge.to_h
    )
  end

  def test_message_payload_excludes_position
    edge = Edge.build(from: "A", to: "B", kind: "include", path: "a.rb", line: 3)
    payload = edge.to_message_payload
    refute_includes payload.keys, "path"
    refute_includes payload.keys, "line"
    assert_equal "include", payload["kind"]
  end

  def test_dedup_key_ignores_path_and_line
    e1 = Edge.build(from: "A", to: "B", kind: "include", path: "x.rb", line: 1)
    e2 = Edge.build(from: "A", to: "B", kind: "include", path: "y.rb", line: 9)
    assert_equal e1.dedup_key, e2.dedup_key
  end

  def test_edgeio_round_trip_with_dedup
    edges = [
      Edge.build(from: "A", to: "B", kind: "include"),
      Edge.build(from: "A", to: "B", kind: "include", path: "elsewhere.rb"),
      Edge.build(from: "A", to: "C", kind: "inherits")
    ]
    io = StringIO.new
    EdgeIO.write(edges, io)
    io.rewind
    read_back = EdgeIO.read(io)
    assert_equal 2, read_back.size
    assert_equal "B", read_back[0].to
    assert_equal "C", read_back[1].to
  end

  def test_to_h_with_raw_field
    edge = Edge.build(from: "A", to: "B", kind: "include",
                      raw: "some_local", confidence: "unresolved")
    h = edge.to_h
    assert_equal "some_local", h["raw"]
  end

  def test_to_json_returns_string
    edge = Edge.build(from: "A", to: "B", kind: "include")
    assert_includes edge.to_json, "\"from\":\"A\""
  end

  def test_message_payload_includes_raw_when_present
    edge = Edge.build(from: "A", to: "B", kind: "include",
                      raw: "x", confidence: "unresolved")
    assert_equal "x", edge.to_message_payload["raw"]
  end

  def test_edgeio_read_defaults_missing_confidence_to_syntax
    io = StringIO.new('{"from":"A","to":"B","kind":"include"}')
    edges = EdgeIO.read(io)
    assert_equal "syntax", edges.first.confidence
  end

  def test_edgeio_skips_blank_lines
    io = StringIO.new(<<~JSONL)
      {"from":"A","to":"B","kind":"include","confidence":"syntax"}

      {"from":"A","to":"C","kind":"inherits","confidence":"syntax"}
    JSONL
    edges = EdgeIO.read(io)
    assert_equal 2, edges.size
  end
end
