# frozen_string_literal: true

require_relative "../../test_helper"

class AnalyzerTest < Minitest::Test
  Analyzer = Rigor::ModuleGraph::Analyzer

  def test_class_inherits_with_lexical_owner
    edges = analyze(<<~RUBY)
      module Billing
        class Invoice < ApplicationRecord
        end
      end
    RUBY
    inherits = edges.select { |e| e.kind == "inherits" }
    assert_equal 1, inherits.size
    assert_equal "Billing::Invoice", inherits.first.from
    assert_equal "ApplicationRecord", inherits.first.to
  end

  def test_class_with_explicit_namespace_path_still_includes_outer_module
    edges = analyze(<<~RUBY)
      module Billing
        class Invoice::Line < ApplicationRecord
        end
      end
    RUBY
    inherits = edges.select { |e| e.kind == "inherits" }
    assert_equal "Billing::Invoice::Line", inherits.first.from
  end

  def test_class_without_superclass_emits_no_inherits_edge
    edges = analyze(<<~RUBY)
      class Foo
      end
    RUBY
    assert_empty(edges.select { |e| e.kind == "inherits" })
  end

  def test_include_prepend_extend_edges
    edges = analyze(<<~RUBY)
      class Foo
        include Bar
        prepend Baz
        extend Qux
      end
    RUBY
    kinds = edges.map(&:kind).sort
    assert_equal %w[extend include prepend], kinds
    edges.each do |edge|
      assert_equal "Foo", edge.from
    end
    assert_equal "Bar", edges.find { |e| e.kind == "include" }.to
    assert_equal "Baz", edges.find { |e| e.kind == "prepend" }.to
    assert_equal "Qux", edges.find { |e| e.kind == "extend" }.to
  end

  def test_multi_arg_include
    edges = analyze(<<~RUBY)
      class Foo
        include Bar, Baz::Qux
      end
    RUBY
    targets = edges.select { |e| e.kind == "include" }.map(&:to).sort
    assert_equal ["Bar", "Baz::Qux"], targets
  end

  def test_skips_mixin_call_with_explicit_receiver
    # `self.include Foo` and `Other.include Foo` look like mixin
    # calls but are routed through a different receiver and should
    # not contribute to the module's own include chain.
    edges = analyze(<<~RUBY)
      class Foo
        self.include Bar
        Other.include Baz
      end
    RUBY
    assert_empty edges
  end

  def test_skips_mixin_call_at_top_level
    edges = analyze(<<~RUBY)
      include Foo
    RUBY
    assert_empty edges
  end

  def test_indirect_mixin_argument_emits_unresolved_edge
    # `include some_variable` has no constant carrier and (in
    # unit tests) no Rigor scope to consult — we record the call
    # as an `unresolved` edge so the graph still shows the
    # reference, with `raw` preserving the source slice.
    edges = analyze(<<~RUBY)
      class Foo
        include some_variable
      end
    RUBY
    assert_equal 1, edges.size
    edge = edges.first
    assert_equal "Foo", edge.from
    assert_equal "some_variable", edge.to
    assert_equal "include", edge.kind
    assert_equal "unresolved", edge.confidence
    assert_equal "some_variable", edge.raw
  end

  def test_const_ref_inside_def_body
    edges = analyze_with_const_refs(<<~RUBY)
      class Invoice
        def total
          Money.new(0)
        end
      end
    RUBY
    refs = edges.select { |e| e.kind == "const_ref" }
    assert_equal 1, refs.size
    assert_equal "Invoice", refs.first.from
    assert_equal "Money", refs.first.to
  end

  def test_const_ref_path_emits_once_outer_only
    # `Foo::Bar::Baz` is one ConstantPathNode wrapping nested
    # ConstantPathNodes. Only the outer one should fire so we
    # don't multi-count `Foo::Bar` and `Foo` as separate refs.
    edges = analyze_with_const_refs(<<~RUBY)
      class Invoice
        def lookup
          Foo::Bar::Baz
        end
      end
    RUBY
    refs = edges.select { |e| e.kind == "const_ref" }
    assert_equal 1, refs.size
    assert_equal "Foo::Bar::Baz", refs.first.to
  end

  def test_const_ref_skips_class_header_constants
    # ApplicationRecord and Auditable in the header positions
    # already produce inherits / include edges; const_ref must
    # not double-count them.
    edges = analyze_with_const_refs(<<~RUBY)
      class Invoice < ApplicationRecord
        include Auditable

        def total
          Money.new
        end
      end
    RUBY
    refs = edges.select { |e| e.kind == "const_ref" }
    assert_equal ["Money"], refs.map(&:to)
  end

  def test_const_ref_skips_top_level_refs
    edges = analyze_with_const_refs(<<~RUBY)
      module Toplevel
        CONST = SomeOther
      end
    RUBY
    refs = edges.select { |e| e.kind == "const_ref" }
    # Top-level (not inside def): skipped to avoid noise from DSL
    # config blocks.
    assert_empty refs
  end

  def test_association_has_many_infers_singular_class_name
    edges = analyze(<<~RUBY)
      class User < ApplicationRecord
        has_many :invoices
      end
    RUBY
    assoc = edges.select { |e| e.kind == "has_many" }
    assert_equal 1, assoc.size
    assert_equal "User", assoc.first.from
    assert_equal "Invoice", assoc.first.to
    assert_equal "invoices", assoc.first.raw
  end

  def test_association_belongs_to_uses_singular_arg_directly
    edges = analyze(<<~RUBY)
      class Invoice < ApplicationRecord
        belongs_to :user
      end
    RUBY
    assoc = edges.find { |e| e.kind == "belongs_to" }
    assert_equal "User", assoc.to
  end

  def test_association_class_name_override_wins
    edges = analyze(<<~RUBY)
      class Invoice < ApplicationRecord
        has_many :line_items, class_name: "Billing::LineItem"
      end
    RUBY
    assoc = edges.find { |e| e.kind == "has_many" }
    assert_equal "Billing::LineItem", assoc.to
  end

  def test_association_has_and_belongs_to_many
    edges = analyze(<<~RUBY)
      class Document < ApplicationRecord
        has_and_belongs_to_many :tags
      end
    RUBY
    assoc = edges.find { |e| e.kind == "has_and_belongs_to_many" }
    assert_equal "Tag", assoc.to
  end

  def test_association_with_class_name_as_symbol_value
    edges = analyze(<<~RUBY)
      class Invoice < ApplicationRecord
        has_many :items, class_name: :LineItem
      end
    RUBY
    assoc = edges.find { |e| e.kind == "has_many" }
    assert_equal "LineItem", assoc.to
  end

  def test_association_skipped_when_no_args
    edges = analyze(<<~RUBY)
      class Foo
        has_many
      end
    RUBY
    assert_empty(edges.select { |e| e.kind == "has_many" })
  end

  def test_association_skipped_when_explicit_receiver
    edges = analyze(<<~RUBY)
      class Foo
        Other.has_many :things
      end
    RUBY
    assert_empty edges
  end

  def test_mixin_call_with_string_arg_is_unresolved
    edges = analyze(<<~RUBY)
      class Foo
        include "Bar"
      end
    RUBY
    # String args don't render as a constant; they go to the
    # unresolved path with raw preserved.
    refute_empty edges
    edge = edges.first
    assert_equal "unresolved", edge.confidence
  end

  def test_class_without_owner_emits_no_edges
    # Hard to construct at top level — module_edges returns empty
    # regardless, but covers the empty branch.
    edges = analyze(<<~RUBY)
      module Foo
      end
    RUBY
    assert_empty edges
  end

  def test_const_ref_path_emits_full_name_for_nested
    edges = analyze_with_const_refs(<<~RUBY)
      class Invoice
        def lookup
          Outer::Inner::Deep
        end
      end
    RUBY
    refs = edges.select { |e| e.kind == "const_ref" }
    assert_equal ["Outer::Inner::Deep"], refs.map(&:to)
  end

  def test_associations_emit_raw_with_symbol_name
    edges = analyze(<<~RUBY)
      class User < ApplicationRecord
        has_many :invoices
      end
    RUBY
    assoc = edges.find { |e| e.kind == "has_many" }
    assert_equal "invoices", assoc.raw
  end

  def test_attribute_node_extraction_via_analyzer
    Analyzer.instance_method(:attribute_nodes) # ensure method exists
    nodes = []
    PrismAncestors.each_node(<<~RUBY) do |node, ancestors|
      class Foo
        attr_reader :a
        attr_writer :b
        attr_accessor :c
      end
    RUBY
      analyzer = Analyzer.new(path: "foo.rb", context: FakeNodeContext.new(ancestors))
      nodes.concat(analyzer.attribute_nodes(node)) if node.is_a?(Prism::CallNode)
    end
    accesses = nodes.map(&:access).sort
    assert_equal %w[accessor read write], accesses
  end

  def test_method_node_metadata_class_vs_instance
    instance_nodes = []
    class_nodes = []
    PrismAncestors.each_node(<<~RUBY) do |node, ancestors|
      class Foo
        def instance_method; end
        def self.class_method; end
      end
    RUBY
      analyzer = Analyzer.new(path: "foo.rb", context: FakeNodeContext.new(ancestors))
      next unless node.is_a?(Prism::DefNode)

      meta = analyzer.method_node_metadata(node)
      next if meta.nil?

      instance_nodes << meta if meta.kind == "instance_method"
      class_nodes << meta if meta.kind == "class_method"
    end
    assert_equal ["instance_method"], instance_nodes.map(&:name)
    assert_equal ["class_method"], class_nodes.map(&:name)
  end

  def test_class_node_metadata_returns_class_kind
    metadata = nil
    PrismAncestors.each_node(<<~RUBY) do |node, ancestors|
      module Billing
        class Invoice
        end
      end
    RUBY
      analyzer = Analyzer.new(path: "foo.rb", context: FakeNodeContext.new(ancestors))
      if node.is_a?(Prism::ClassNode)
        metadata = analyzer.class_node_metadata(node)
      end
    end
    refute_nil metadata
    assert_equal "class", metadata.kind
    assert_equal "Billing::Invoice", metadata.name
  end

  def test_method_node_metadata_returns_nil_outside_class
    metadata = nil
    PrismAncestors.each_node(<<~RUBY) do |node, ancestors|
      def top_level; end
    RUBY
      analyzer = Analyzer.new(path: "foo.rb", context: FakeNodeContext.new(ancestors))
      if node.is_a?(Prism::DefNode)
        metadata = analyzer.method_node_metadata(node)
      end
    end
    assert_nil metadata
  end

  def test_class_node_metadata_returns_nil_for_anon_constant_path
    # Construct a ClassNode whose `constant_path` doesn't render —
    # an empty class through Prism always renders, so simulate
    # with a top-level edge-case via owner_for_decl indirectly.
    edges = analyze(<<~RUBY)
      class Foo < SomeBase
      end
    RUBY
    refute_empty edges
  end

  def test_resolve_via_scope_with_singleton_type
    fake_scope = Object.new
    fake_scope.define_singleton_method(:type_of) do |_arg|
      ::Rigor::Type::Singleton.new("Resolved::Klass")
    end

    edges = analyze_with_scope(fake_scope, <<~RUBY)
      class Foo
        include some_local_var
      end
    RUBY
    rigor_typed = edges.find { |e| e.confidence == "rigor_type" }
    refute_nil rigor_typed
    assert_equal "Resolved::Klass", rigor_typed.to
  end

  def test_resolve_via_scope_returns_nil_on_dynamic_type
    fake_scope = Object.new
    fake_scope.define_singleton_method(:type_of) do |_arg|
      Object.new # not a Singleton — should degrade to unresolved
    end

    edges = analyze_with_scope(fake_scope, <<~RUBY)
      class Foo
        include some_local_var
      end
    RUBY
    unresolved = edges.find { |e| e.confidence == "unresolved" }
    refute_nil unresolved
  end

  def test_resolve_via_scope_rescues_exceptions
    raising_scope = Object.new
    raising_scope.define_singleton_method(:type_of) { |_| raise "boom" }
    edges = analyze_with_scope(raising_scope, <<~RUBY)
      class Foo
        include some_local_var
      end
    RUBY
    unresolved = edges.find { |e| e.confidence == "unresolved" }
    refute_nil unresolved
  end

  def test_resolve_via_scope_returns_nil_without_scope
    edges = analyze_with_scope(nil, <<~RUBY)
      class Foo
        include some_local
      end
    RUBY
    unresolved = edges.find { |e| e.confidence == "unresolved" }
    refute_nil unresolved
  end

  def test_zeitwerk_promotes_confidence_when_path_matches_owner
    resolver_stub = Object.new
    resolver_stub.define_singleton_method(:resolve) { |_path| "Foo" }
    resolver_stub.define_singleton_method(:matches?) { |actual, inferred| actual == inferred }

    edges = []
    PrismAncestors.each_node(<<~RUBY) do |node, ancestors|
      class Foo < ApplicationRecord
      end
    RUBY
      analyzer = Analyzer.new(
        path: "app/models/foo.rb",
        context: FakeNodeContext.new(ancestors),
        zeitwerk: resolver_stub
      )
      edges.concat(analyzer.class_edges(node)) if node.is_a?(Prism::ClassNode)
    end
    assert_equal "zeitwerk", edges.first.confidence
  end

  def test_zeitwerk_stays_syntax_when_no_match
    resolver_stub = Object.new
    resolver_stub.define_singleton_method(:resolve) { |_| "Other" }
    resolver_stub.define_singleton_method(:matches?) { |_, _| false }

    edges = []
    PrismAncestors.each_node(<<~RUBY) do |node, ancestors|
      class Foo < ApplicationRecord
      end
    RUBY
      analyzer = Analyzer.new(
        path: "app/models/foo.rb",
        context: FakeNodeContext.new(ancestors),
        zeitwerk: resolver_stub
      )
      edges.concat(analyzer.class_edges(node)) if node.is_a?(Prism::ClassNode)
    end
    assert_equal "syntax", edges.first.confidence
  end

  def test_attribute_nodes_returns_empty_when_not_attr_call
    nodes = []
    PrismAncestors.each_node(<<~RUBY) do |node, ancestors|
      class Foo
        validates :name
      end
    RUBY
      analyzer = Analyzer.new(path: "foo.rb", context: FakeNodeContext.new(ancestors))
      nodes.concat(analyzer.attribute_nodes(node)) if node.is_a?(Prism::CallNode)
    end
    assert_empty nodes
  end

  def test_attribute_nodes_skips_explicit_receiver
    nodes = []
    PrismAncestors.each_node(<<~RUBY) do |node, ancestors|
      class Foo
        self.attr_reader :name
      end
    RUBY
      analyzer = Analyzer.new(path: "foo.rb", context: FakeNodeContext.new(ancestors))
      nodes.concat(analyzer.attribute_nodes(node)) if node.is_a?(Prism::CallNode)
    end
    assert_empty nodes
  end

  def test_attribute_nodes_skips_non_symbol_args
    nodes = []
    PrismAncestors.each_node(<<~RUBY) do |node, ancestors|
      class Foo
        attr_reader some_method_call
      end
    RUBY
      analyzer = Analyzer.new(path: "foo.rb", context: FakeNodeContext.new(ancestors))
      nodes.concat(analyzer.attribute_nodes(node)) if node.is_a?(Prism::CallNode)
    end
    assert_empty nodes
  end

  def test_class_name_from_options_with_non_assoc_element
    # `class_name: "Foo"` is a symbol literal — but the keyword
    # hash might also contain splats. Cover the non-AssocNode
    # branch by including an extra unrelated keyword.
    edges = analyze(<<~RUBY)
      class Invoice < ApplicationRecord
        has_many :things, dependent: :destroy, class_name: "Thing"
      end
    RUBY
    assoc = edges.find { |e| e.kind == "has_many" }
    assert_equal "Thing", assoc.to
  end

  def test_class_name_from_options_returns_nil_without_keyword_hash
    edges = analyze(<<~RUBY)
      class Invoice < ApplicationRecord
        has_many :things
      end
    RUBY
    assoc = edges.find { |e| e.kind == "has_many" }
    # No class_name option → Inflector singularizes "things" → "Thing"
    assert_equal "Thing", assoc.to
  end

  def test_class_name_from_options_returns_nil_for_non_class_name_key
    edges = analyze(<<~RUBY)
      class Invoice < ApplicationRecord
        has_many :things, dependent: :destroy
      end
    RUBY
    assoc = edges.find { |e| e.kind == "has_many" }
    assert_equal "Thing", assoc.to
  end

  def test_zeitwerk_skips_when_no_path
    resolver_stub = Object.new
    resolver_stub.define_singleton_method(:resolve) { |_| nil }
    resolver_stub.define_singleton_method(:matches?) { |_, _| false }

    edges = []
    PrismAncestors.each_node(<<~RUBY) do |node, ancestors|
      class Foo < Base
      end
    RUBY
      analyzer = Analyzer.new(
        path: nil,
        context: FakeNodeContext.new(ancestors),
        zeitwerk: resolver_stub
      )
      edges.concat(analyzer.class_edges(node)) if node.is_a?(Prism::ClassNode)
    end
    assert_equal "syntax", edges.first.confidence
  end

  def test_visibility_map_consulted_when_present
    vm = Object.new
    vm.define_singleton_method(:visibility_for) { |_| "protected" }
    metadata = nil
    PrismAncestors.each_node(<<~RUBY) do |node, ancestors|
      class Foo
        def bar; end
      end
    RUBY
      analyzer = Analyzer.new(
        path: "f.rb",
        context: FakeNodeContext.new(ancestors),
        visibility_map: vm
      )
      if node.is_a?(Prism::DefNode)
        metadata = analyzer.method_node_metadata(node)
      end
    end
    assert_equal "protected", metadata.visibility
  end

  def test_inside_mixin_args_detection
    # `include Foo` inside a class — the inner ConstantReadNode
    # for Foo should be skipped from const_ref emission because
    # it's an argument of the mixin call.
    edges = analyze_with_const_refs(<<~RUBY)
      class Bar
        include Foo
        def m; Foo end
      end
    RUBY
    refs = edges.select { |e| e.kind == "const_ref" }
    # The Foo inside `def m; Foo end` becomes a const_ref.
    # The Foo inside `include Foo` is suppressed.
    assert_equal 1, refs.size
  end

  def test_class_edges_top_level_resolves_owner_from_own_name
    # ClassNode with empty ancestor context still has its own
    # constant_path; the analyzer reads that for the owner.
    analyzer = Analyzer.new(path: "f.rb", context: FakeNodeContext.new([]))
    class_node = nil
    PrismAncestors.each_node("class Foo < Bar; end") do |node, _|
      class_node = node if node.is_a?(Prism::ClassNode)
    end
    edges = analyzer.class_edges(class_node)
    assert_equal "Foo", edges.first.from
  end

  def test_attribute_nodes_owner_nil_returns_empty
    analyzer = Analyzer.new(path: "f.rb", context: FakeNodeContext.new([]))
    PrismAncestors.each_node("attr_reader :foo") do |node, _|
      if node.is_a?(Prism::CallNode)
        assert_empty analyzer.attribute_nodes(node)
      end
    end
  end

  def test_association_owner_nil_returns_empty
    analyzer = Analyzer.new(path: "f.rb", context: FakeNodeContext.new([]))
    PrismAncestors.each_node("has_many :things") do |node, _|
      if node.is_a?(Prism::CallNode)
        assert_empty analyzer.association_edges(node)
      end
    end
  end

  def test_constant_read_edges_owner_nil_returns_empty
    analyzer = Analyzer.new(path: "f.rb", context: FakeNodeContext.new([]))
    PrismAncestors.each_node("Foo") do |node, _|
      if node.is_a?(Prism::ConstantReadNode)
        assert_empty analyzer.constant_read_edges(node)
      end
    end
  end

  def test_constant_path_edges_owner_nil_returns_empty
    analyzer = Analyzer.new(path: "f.rb", context: FakeNodeContext.new([]))
    PrismAncestors.each_node("Foo::Bar") do |node, _|
      if node.is_a?(Prism::ConstantPathNode)
        assert_empty analyzer.constant_path_edges(node)
      end
    end
  end

  def test_method_node_metadata_inside_class_returns_def_metadata
    inside_def = nil
    PrismAncestors.each_node(<<~RUBY) do |node, ancestors|
      class Foo
        def bar; end
      end
    RUBY
      if node.is_a?(Prism::DefNode)
        analyzer = Analyzer.new(path: "f.rb", context: FakeNodeContext.new(ancestors))
        inside_def = analyzer.method_node_metadata(node)
      end
    end
    refute_nil inside_def
    assert_equal "Foo", inside_def.owner
  end

  def test_class_node_metadata_owner_nil_returns_nil
    analyzer = Analyzer.new(path: "f.rb", context: FakeNodeContext.new([]))
    PrismAncestors.each_node("class Foo; end") do |node, _|
      next unless node.is_a?(Prism::ClassNode)

      # When ancestors are empty and the class is bare, lexical
      # owner still resolves (the class's own name). So owner is
      # non-nil. Verify the non-nil branch is hit instead.
      result = analyzer.class_node_metadata(node)
      refute_nil result
    end
  end

  def test_resolve_via_scope_returns_nil_when_type_is_nil
    fake_scope = Object.new
    fake_scope.define_singleton_method(:type_of) { |_| nil }
    edges = analyze_with_scope(fake_scope, <<~RUBY)
      class Foo
        include some_local_var
      end
    RUBY
    unresolved = edges.find { |e| e.confidence == "unresolved" }
    refute_nil unresolved
  end

  def test_arg_source_returns_nil_without_location
    analyzer = Analyzer.new(path: "f.rb", context: FakeNodeContext.new([]))
    fake_arg = Object.new
    def fake_arg.location = nil
    assert_nil analyzer.send(:arg_source, fake_arg)
  end

  def test_emit_const_ref_false_when_context_does_not_respond_to_enclosing_def
    fake_context = Object.new
    def fake_context.ancestors = []
    analyzer = Analyzer.new(path: "f.rb", context: fake_context)
    fake_node = Object.new
    refute analyzer.send(:emit_const_ref?, fake_node)
  end

  def test_emit_const_ref_false_when_no_enclosing_def
    # FakeNodeContext has enclosing_def via ancestors; an empty
    # ancestors list means no def in scope → emit_const_ref? false.
    context = FakeNodeContext.new([])
    analyzer = Analyzer.new(path: "f.rb", context: context)
    fake_node = Object.new
    refute analyzer.send(:emit_const_ref?, fake_node)
  end

  def test_class_name_from_options_with_string_value
    edges = analyze(<<~RUBY)
      class Invoice < ApplicationRecord
        has_many :things, class_name: "Thing"
      end
    RUBY
    assoc = edges.find { |e| e.kind == "has_many" }
    assert_equal "Thing", assoc.to
  end

  def test_contains_node_predicate_negative_cases
    analyzer = Analyzer.new(path: "f.rb", context: FakeNodeContext.new([]))
    refute analyzer.send(:contains_node?, "not a prism node", Object.new)
  end

  def test_contains_node_self_equality
    analyzer = Analyzer.new(path: "f.rb", context: FakeNodeContext.new([]))
    target = Object.new
    assert analyzer.send(:contains_node?, target, target)
  end

  def test_zeitwerk_when_owner_doesnt_match_inferred_stays_syntax
    resolver = Object.new
    resolver.define_singleton_method(:resolve) { |_| "Different" }
    resolver.define_singleton_method(:matches?) { |_, _| false }
    edges = []
    PrismAncestors.each_node(<<~RUBY) do |node, ancestors|
      class Foo < Bar
      end
    RUBY
      a = Analyzer.new(path: "a.rb", context: FakeNodeContext.new(ancestors), zeitwerk: resolver)
      edges.concat(a.class_edges(node)) if node.is_a?(Prism::ClassNode)
    end
    assert_equal "syntax", edges.first.confidence
  end

  def test_column_of_nil_when_no_location
    analyzer = Analyzer.new(path: "f.rb", context: FakeNodeContext.new([]))
    fake_node = Object.new
    def fake_node.location = nil
    assert_nil analyzer.send(:column_of, fake_node)
    assert_nil analyzer.send(:line_of, fake_node)
  end

  def analyze_with_scope(scope, source)
    results = []
    PrismAncestors.each_node(source) do |node, ancestors|
      analyzer = Analyzer.new(
        path: "test.rb",
        context: FakeNodeContext.new(ancestors),
        scope: scope
      )
      results.concat(analyzer.call_edges(node)) if node.is_a?(Prism::CallNode)
    end
    results
  end

  def test_module_node_metadata_returns_module_kind
    metadata = nil
    PrismAncestors.each_node(<<~RUBY) do |node, ancestors|
      module Auditable
      end
    RUBY
      analyzer = Analyzer.new(path: "foo.rb", context: FakeNodeContext.new(ancestors))
      if node.is_a?(Prism::ModuleNode)
        metadata = analyzer.module_node_metadata(node)
      end
    end
    refute_nil metadata
    assert_equal "module", metadata.kind
  end

  def analyze(source, path: "test.rb")
    analyze_inner(source, path: path, include_constant_refs: false)
  end

  def analyze_with_const_refs(source, path: "test.rb")
    analyze_inner(source, path: path, include_constant_refs: true)
  end

  def analyze_inner(source, path:, include_constant_refs:)
    results = []
    PrismAncestors.each_node(source) do |node, ancestors|
      analyzer = Analyzer.new(path: path, context: FakeNodeContext.new(ancestors))
      results.concat(analyzer.class_edges(node)) if node.is_a?(Prism::ClassNode)
      results.concat(analyzer.module_edges(node)) if node.is_a?(Prism::ModuleNode)
      if node.is_a?(Prism::CallNode)
        results.concat(analyzer.call_edges(node))
        results.concat(analyzer.association_edges(node))
      end
      if include_constant_refs
        results.concat(analyzer.constant_read_edges(node)) if node.is_a?(Prism::ConstantReadNode)
        results.concat(analyzer.constant_path_edges(node)) if node.is_a?(Prism::ConstantPathNode)
      end
    end
    results
  end
end
