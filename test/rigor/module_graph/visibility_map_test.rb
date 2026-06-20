# frozen_string_literal: true

require_relative "../../test_helper"
require "prism"

class VisibilityMapTest < Minitest::Test
  VisibilityMap = Rigor::ModuleGraph::VisibilityMap

  def build(source)
    root = Prism.parse(source).value
    [VisibilityMap.build(root), find_defs(root)]
  end

  def find_defs(node, defs = {})
    return defs unless node.is_a?(Prism::Node)

    if node.is_a?(Prism::DefNode)
      defs[node.name.to_s] = node
    end
    node.compact_child_nodes.each { |c| find_defs(c, defs) }
    defs
  end

  def test_default_visibility_is_public
    map, defs = build(<<~RUBY)
      class Foo
        def bar; end
      end
    RUBY
    assert_equal "public", map.visibility_for(defs["bar"])
  end

  def test_bare_private_flips_subsequent_defs
    map, defs = build(<<~RUBY)
      class Foo
        def public_one; end
        private
        def secret; end
        def another_secret; end
      end
    RUBY
    assert_equal "public", map.visibility_for(defs["public_one"])
    assert_equal "private", map.visibility_for(defs["secret"])
    assert_equal "private", map.visibility_for(defs["another_secret"])
  end

  def test_protected_then_public_flips_again
    map, defs = build(<<~RUBY)
      class Foo
        protected
        def mid; end
        public
        def open; end
      end
    RUBY
    assert_equal "protected", map.visibility_for(defs["mid"])
    assert_equal "public", map.visibility_for(defs["open"])
  end

  def test_private_with_explicit_symbols_is_ignored_for_running_visibility
    # `private :foo` doesn't flip the running visibility — only
    # bare `private` does. This matches the documented MVP.
    map, defs = build(<<~RUBY)
      class Foo
        private :hidden
        def open; end
        def hidden; end
      end
    RUBY
    assert_equal "public", map.visibility_for(defs["open"])
    assert_equal "public", map.visibility_for(defs["hidden"])
  end

  def test_nested_module_resets_visibility_to_public
    # Visibility starts public at every class/module body entry,
    # so the inner Bar.greet is public even though Foo's body
    # had flipped to private.
    map, defs = build(<<~RUBY)
      class Foo
        private
        def secret; end

        module Bar
          def greet; end
        end
      end
    RUBY
    assert_equal "private", map.visibility_for(defs["secret"])
    assert_equal "public", map.visibility_for(defs["greet"])
  end

  def test_top_level_def_is_recorded_through_program_node
    map, defs = build(<<~RUBY)
      module Outer
        class Inner
          private
          def x; end
        end
      end
    RUBY
    assert_equal "private", map.visibility_for(defs["x"])
  end

  def test_def_not_in_map_returns_nil_when_no_body
    map, _defs = build("class Foo; end")
    assert_nil map.visibility_for(Object.new)
  end

  def test_build_tolerates_nil_root
    map = VisibilityMap.build(nil)
    assert_instance_of VisibilityMap, map
    assert_nil map.visibility_for(Object.new)
  end

  def test_bare_marker_requires_no_receiver
    # `Foo.private` shouldn't flip the running visibility, only
    # the keyword-style bare call.
    map, defs = build(<<~RUBY)
      class Foo
        Other.private
        def open; end
      end
    RUBY
    assert_equal "public", map.visibility_for(defs["open"])
  end

  def test_module_top_level_visibility
    map, defs = build(<<~RUBY)
      module Helpers
        private
        def helper; end
      end
    RUBY
    assert_equal "private", map.visibility_for(defs["helper"])
  end

  def test_walk_skips_non_node_input
    # `walk_top_level` returns early for nil; cover the guard.
    assert_silent { VisibilityMap.walk_top_level(nil, VisibilityMap.new) }
  end

  def test_walk_skips_arbitrary_top_level_statement
    map, _defs = build("class Foo; end; 42")
    # The trailing integer is not a class/module; walk_top_level
    # falls through the case with no match.
    assert_instance_of VisibilityMap, map
  end

  def test_marker_with_receiver_does_not_flip
    map, defs = build(<<~RUBY)
      class Foo
        bar.private
        def open; end
      end
    RUBY
    assert_equal "public", map.visibility_for(defs["open"])
  end
end
