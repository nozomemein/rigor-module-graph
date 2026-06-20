# frozen_string_literal: true

require_relative "../../test_helper"

class ConstantNameTest < Minitest::Test
  ConstantName = Rigor::ModuleGraph::ConstantName

  def test_renders_bare_constant_read
    node = parse_const("Foo")
    assert_equal "Foo", ConstantName.render(node)
  end

  def test_renders_relative_constant_path
    node = parse_const("Foo::Bar::Baz")
    assert_equal "Foo::Bar::Baz", ConstantName.render(node)
  end

  def test_renders_absolute_constant_path
    node = parse_const("::Foo::Bar")
    assert_equal "::Foo::Bar", ConstantName.render(node)
  end

  def test_render_returns_nil_for_non_constant_nodes
    node = Prism.parse("foo").value.statements.body.first
    assert_nil ConstantName.render(node)
  end

  def test_lexical_owner_joins_module_and_class_ancestors
    ancestors = capture_ancestors_for("Inner") do |src|
      <<~RUBY
        module Outer
          class Middle
            #{src}
          end
        end
      RUBY
    end
    context = FakeNodeContext.new(ancestors)
    assert_equal "Outer::Middle", ConstantName.lexical_owner(context)
  end

  def test_lexical_owner_with_appends_extra_part
    ancestors = capture_ancestors_for("Inner") do |src|
      <<~RUBY
        module Outer
          #{src}
        end
      RUBY
    end
    context = FakeNodeContext.new(ancestors)
    assert_equal "Outer::Self", ConstantName.lexical_owner_with(context, "Self")
  end

  def test_lexical_owner_handles_dotted_class_names
    ancestors = capture_ancestors_for("Inner") do |src|
      <<~RUBY
        module Billing
          class Invoice::Line
            #{src}
          end
        end
      RUBY
    end
    context = FakeNodeContext.new(ancestors)
    assert_equal "Billing::Invoice::Line", ConstantName.lexical_owner(context)
  end

  def test_lexical_owner_returns_nil_when_no_enclosing_module
    context = FakeNodeContext.new([])
    assert_nil ConstantName.lexical_owner(context)
  end

  def test_lexical_owner_with_returns_nil_when_extra_empty_and_no_ancestors
    context = FakeNodeContext.new([])
    assert_nil ConstantName.lexical_owner_with(context, "")
    assert_nil ConstantName.lexical_owner_with(context, nil)
  end

  def test_lexical_parts_ignores_non_class_module_ancestors
    # DefNode etc. should be filtered out.
    src = "def foo; class Inner; end; end"
    ancestors_around_inner = nil
    PrismAncestors.each_node(src) do |node, ancestors|
      if node.is_a?(Prism::ClassNode) && node.name == :Inner
        ancestors_around_inner = ancestors.dup
      end
    end
    refute_nil ancestors_around_inner
    parts = ConstantName.lexical_parts(ancestors_around_inner)
    assert_empty parts
  end

  def parse_const(source)
    Prism.parse(source).value.statements.body.first
  end

  # Parse the wrapped source (yielded as a template with a sentinel
  # marker `src`), find the inner sentinel `Inner` ConstantReadNode,
  # and return its ancestor chain. This is how we drive Analyzer
  # tests without booting rigortype.
  def capture_ancestors_for(sentinel)
    source = yield(sentinel.to_s)
    captured = nil
    PrismAncestors.each_node(source) do |node, ancestors|
      if node.is_a?(Prism::ConstantReadNode) && node.name.to_s == sentinel
        captured = ancestors.dup
      end
    end
    refute_nil captured, "expected to find sentinel #{sentinel} in source\n#{source}"
    captured
  end
end
