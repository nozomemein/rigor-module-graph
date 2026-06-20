# frozen_string_literal: true

require_relative "../../../test_helper"

class ViewerHtmlTest < Minitest::Test
  def edges
    [
      Rigor::ModuleGraph::Edge.build(
        from: "Billing::Invoice", to: "ApplicationRecord",
        kind: "inherits", confidence: "syntax",
        path: "app/models/billing/invoice.rb", line: 2
      ),
      Rigor::ModuleGraph::Edge.build(
        from: "Billing::Invoice", to: "Auditable",
        kind: "include", confidence: "zeitwerk",
        path: "app/models/billing/invoice.rb", line: 3
      )
    ]
  end

  def nodes
    [
      Rigor::ModuleGraph::Node.build(
        kind: "class", name: "Invoice", owner: "Billing",
        path: "app/models/billing/invoice.rb", line: 1
      )
    ]
  end

  # build_data — payload sanity (cheap, doesn't read template files)

  def test_build_data_includes_locally_defined_nodes_with_metadata
    data = Rigor::ModuleGraph::Viewer::Html.build_data(
      edges: edges, nodes: nodes, path_mode: :relative, open_with: nil
    )
    invoice = data[:nodes].find { |n| n[:data][:name] == "Billing::Invoice" }
    assert invoice, "Billing::Invoice node expected"
    assert_equal "class", invoice[:data][:kind]
    assert_equal "app/models/billing/invoice.rb", invoice[:data][:path]
    assert_equal 1, invoice[:data][:line]
  end

  def test_build_data_synthesises_external_endpoints
    # ApplicationRecord and Auditable have no nodes.jsonl entry —
    # they should still appear as Cytoscape nodes so the edges
    # have endpoints, marked `external` so the styling can dim
    # them.
    data = Rigor::ModuleGraph::Viewer::Html.build_data(
      edges: edges, nodes: nodes, path_mode: :relative, open_with: nil
    )
    external_names = data[:nodes]
                     .select { |n| n[:data][:kind] == "external" }
                     .map { |n| n[:data][:name] }
                     .sort
    assert_equal %w[ApplicationRecord Auditable], external_names
  end

  def test_build_data_path_mode_none_strips_paths
    data = Rigor::ModuleGraph::Viewer::Html.build_data(
      edges: edges, nodes: nodes, path_mode: :none, open_with: nil
    )
    invoice = data[:nodes].find { |n| n[:data][:name] == "Billing::Invoice" }
    assert_nil invoice[:data][:path]
  end

  def test_build_data_path_mode_absolute_expands
    data = Rigor::ModuleGraph::Viewer::Html.build_data(
      edges: edges, nodes: nodes, path_mode: :absolute, open_with: nil
    )
    invoice = data[:nodes].find { |n| n[:data][:name] == "Billing::Invoice" }
    assert invoice[:data][:path].start_with?("/"),
           "expected absolute path, got #{invoice[:data][:path].inspect}"
  end

  def test_build_data_open_with_vscode_propagates_to_options
    data = Rigor::ModuleGraph::Viewer::Html.build_data(
      edges: edges, nodes: nodes, path_mode: :relative, open_with: :vscode
    )
    assert_equal "vscode", data[:options][:open_with]
  end

  def test_build_data_dedups_class_reopens_to_one_node
    extra = Rigor::ModuleGraph::Node.build(
      kind: "class", name: "Invoice", owner: "Billing",
      path: "app/models/billing/invoice_decorator.rb", line: 1
    )
    data = Rigor::ModuleGraph::Viewer::Html.build_data(
      edges: edges, nodes: nodes + [extra],
      path_mode: :relative, open_with: nil
    )
    invoices = data[:nodes].select { |n| n[:data][:name] == "Billing::Invoice" }
    assert_equal 1, invoices.length
    # first-wins: the original definition path is kept
    assert_equal "app/models/billing/invoice.rb", invoices.first[:data][:path]
  end

  def test_build_data_skips_method_and_attribute_nodes
    extras = [
      Rigor::ModuleGraph::Node.build(kind: "instance_method", name: "total", owner: "Billing::Invoice"),
      Rigor::ModuleGraph::Node.build(kind: "attribute", name: "amount", owner: "Billing::Invoice")
    ]
    data = Rigor::ModuleGraph::Viewer::Html.build_data(
      edges: edges, nodes: nodes + extras,
      path_mode: :relative, open_with: nil
    )
    refute(data[:nodes].any? { |n| n[:data][:name] =~ /total|amount/ })
  end

  def test_build_data_serialises_edges_with_kind_and_confidence
    data = Rigor::ModuleGraph::Viewer::Html.build_data(
      edges: edges, nodes: nodes, path_mode: :relative, open_with: nil
    )
    assert_equal 2, data[:edges].length
    inherits = data[:edges].find { |e| e[:data][:kind] == "inherits" }
    assert_equal "Billing::Invoice", inherits[:data][:source]
    assert_equal "ApplicationRecord", inherits[:data][:target]
    assert_equal "syntax", inherits[:data][:confidence]
  end

  # render — integration: produces full HTML, embeds JSON safely

  def test_render_produces_self_contained_html
    html = Rigor::ModuleGraph::Viewer::Html.render(
      edges: edges, nodes: nodes, title: "billing example",
      path_mode: :relative
    )
    assert_includes html, "<!DOCTYPE html>"
    assert_includes html, "<title>billing example</title>"
    assert_includes html, 'id="cy"'
    # Embedded data is present
    assert_match(%r{<script[^>]+id="rmg-data"[^>]*>[^<]+</script>}m, html)
    # The vendored cytoscape is inlined (look for a known token
    # from the minified source so we don't pin on file size).
    assert_includes html, "cytoscape"
    # CSP meta header signals no network egress at view time
    assert_includes html, "default-src 'self'"
  end

  def test_render_escapes_closing_script_in_payload
    # If a constant name (or any data field) ever contained
    # `</script>`, naive embedding would break out of the JSON
    # tag. `safe_json` rewrites `</` → `<\/`.
    sneaky = [
      Rigor::ModuleGraph::Edge.build(
        from: "A</script>X", to: "B",
        kind: "inherits", confidence: "syntax"
      )
    ]
    html = Rigor::ModuleGraph::Viewer::Html.render(
      edges: sneaky, nodes: [], title: "t"
    )
    refute_includes html, "A</script>X"
    assert_includes html, "A<\\/script>X"
  end

  def test_render_html_escapes_the_title
    html = Rigor::ModuleGraph::Viewer::Html.render(
      edges: edges, nodes: nodes, title: "<x>"
    )
    refute_includes html, "<title><x>"
    assert_includes html, "<title>&lt;x&gt;</title>"
  end
end
