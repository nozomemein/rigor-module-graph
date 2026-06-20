# frozen_string_literal: true

require_relative "../../test_helper"

class InflectorTest < Minitest::Test
  Inflector = Rigor::ModuleGraph::Inflector

  def test_singularize_drops_trailing_s
    assert_equal "post", Inflector.singularize("posts")
    assert_equal "user", Inflector.singularize("users")
  end

  def test_singularize_handles_ies_to_y
    assert_equal "company", Inflector.singularize("companies")
    assert_equal "policy", Inflector.singularize("policies")
  end

  def test_singularize_handles_irregulars
    assert_equal "person", Inflector.singularize("people")
    assert_equal "child", Inflector.singularize("children")
  end

  def test_singularize_leaves_ss_alone
    assert_equal "class", Inflector.singularize("class")
    assert_equal "boss", Inflector.singularize("boss")
  end

  def test_camelize_snake_case
    assert_equal "FooBarBaz", Inflector.camelize("foo_bar_baz")
    assert_equal "Invoice", Inflector.camelize("invoice")
  end

  def test_class_name_for_combines_singularize_and_camelize
    assert_equal "Invoice", Inflector.class_name_for("invoices")
    assert_equal "LineItem", Inflector.class_name_for("line_items")
    assert_equal "Person", Inflector.class_name_for("people")
    assert_equal "Company", Inflector.class_name_for("companies")
  end

  def test_singularize_handles_empty_word
    assert_equal "", Inflector.singularize("")
  end

  def test_singularize_returns_dup_for_unmatched_words
    assert_equal "data", Inflector.singularize("data")
    assert_equal "fish", Inflector.singularize("fish")
  end

  def test_singularize_handles_ses_suffix
    # `boses` matches the `-ses` rule.
    assert_equal "bos", Inflector.singularize("boses")
  end

  def test_camelize_with_empty_segments
    assert_equal "", Inflector.camelize("")
    assert_equal "Foo", Inflector.camelize("foo")
  end

  def test_preserve_case_capital_propagates
    # `People → Person` should still preserve the leading capital.
    assert_equal "Person", Inflector.singularize("People")
  end

  def test_camelize_with_leading_underscore
    # `_foo` → first segment is empty, should be skipped.
    assert_equal "Foo", Inflector.camelize("_foo")
  end
end
