# frozen_string_literal: true

require_relative "../../test_helper"

class ZeitwerkResolverTest < Minitest::Test
  Resolver = Rigor::ModuleGraph::ZeitwerkResolver

  def test_resolves_simple_model
    assert_equal "Invoice", Resolver.new.resolve("app/models/invoice.rb")
  end

  def test_resolves_namespaced_model
    assert_equal "Billing::Invoice",
                 Resolver.new.resolve("app/models/billing/invoice.rb")
  end

  def test_concern_directory_is_transparent
    assert_equal "Auditable",
                 Resolver.new.resolve("app/models/concerns/auditable.rb")
  end

  def test_camelises_snake_case_segments
    assert_equal "Foo::BarBaz",
                 Resolver.new.resolve("app/services/foo/bar_baz.rb")
  end

  def test_resolves_application_record
    assert_equal "ApplicationRecord",
                 Resolver.new.resolve("app/models/application_record.rb")
  end

  def test_returns_nil_for_paths_outside_autoload_roots
    assert_nil Resolver.new.resolve("vendor/gems/whatever.rb")
    assert_nil Resolver.new.resolve("test/fixtures/x.rb")
  end

  def test_returns_nil_for_non_ruby_files
    assert_nil Resolver.new.resolve("app/models/billing/invoice.yml")
  end

  def test_returns_nil_for_nil_path
    assert_nil Resolver.new.resolve(nil)
  end

  def test_concern_root_takes_priority_over_parent_autoload_root
    # `app/models` and `app/models/concerns` both match — the longer
    # / more specific root wins so we get `Auditable`, not
    # `Concerns::Auditable`.
    resolver = Resolver.new(
      autoload_paths: %w[app/models],
      concern_dirs: %w[app/models/concerns]
    )
    assert_equal "Auditable",
                 resolver.resolve("app/models/concerns/auditable.rb")
  end

  def test_custom_autoload_paths_only
    resolver = Resolver.new(autoload_paths: %w[src], concern_dirs: [])
    assert_equal "Foo::Bar", resolver.resolve("src/foo/bar.rb")
    assert_nil resolver.resolve("app/models/invoice.rb")
  end

  def test_absolute_path_with_project_root_strips_prefix
    resolver = Resolver.new(project_root: "/tmp/proj")
    assert_equal "Billing::Invoice",
                 resolver.resolve("/tmp/proj/app/models/billing/invoice.rb")
  end

  def test_absolute_path_without_project_root_falls_back_to_suffix_match
    # Used by integration runs: we don't know the project root but
    # the path is absolute. Find the autoload root suffix in the
    # absolute path and chop everything before it.
    assert_equal "Billing::Invoice",
                 Resolver.new.resolve("/private/var/folders/X/rigor-tmp/app/models/billing/invoice.rb")
  end

  def test_matches_ignores_leading_colon_colon
    resolver = Resolver.new
    assert resolver.matches?("Billing::Invoice", "Billing::Invoice")
    assert resolver.matches?("::Billing::Invoice", "Billing::Invoice")
    refute resolver.matches?("Billing::Invoice", "Invoice")
    refute resolver.matches?(nil, "Foo")
    refute resolver.matches?("Foo", nil)
  end

  def test_trailing_slashes_in_config_are_normalised
    resolver = Resolver.new(autoload_paths: ["app/models/"])
    assert_equal "Invoice", resolver.resolve("app/models/invoice.rb")
  end

  def test_resolves_returns_nil_when_relative_path_unresolvable
    resolver = Resolver.new(project_root: "/tmp/proj")
    # An absolute path outside project_root that doesn't include
    # any known autoload root prefix.
    assert_nil resolver.resolve("/elsewhere/foo.rb")
  end

  def test_matches_handles_nil_inputs
    refute Resolver.new.matches?(nil, nil)
    refute Resolver.new.matches?("Foo", nil)
    refute Resolver.new.matches?(nil, "Foo")
  end
end
