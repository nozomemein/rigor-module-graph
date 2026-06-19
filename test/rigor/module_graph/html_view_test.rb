# frozen_string_literal: true

require_relative "../../test_helper"

class HtmlViewTest < Minitest::Test
  HtmlView = Rigor::ModuleGraph::HtmlView

  def test_renders_title_subtitle_and_mermaid
    html = HtmlView.render(
      title: "demo",
      subtitle: "2 edge(s)",
      mermaid_source: "flowchart LR\n  A --> B\n"
    )
    assert_includes html, "<title>demo</title>"
    assert_includes html, "<h1>demo</h1>"
    assert_includes html, "2 edge(s)"
    assert_includes html, "flowchart LR"
    # Each non-first line in the mermaid block is indented under
    # the surrounding <pre>; check the original content survives.
    assert_includes html, "A --> B"
    # The CDN import line should be present.
    assert_includes html, "cdn.jsdelivr.net/npm/mermaid@10"
  end

  def test_subtitle_is_optional
    html = HtmlView.render(title: "demo", mermaid_source: "flowchart LR\n")
    refute_includes html, '<p class="meta">'
  end

  def test_legend_lists_all_kinds_and_unresolved
    html = HtmlView.render(title: "demo", mermaid_source: "")
    %w[inherits include prepend extend const_ref unresolved].each do |kind|
      assert_includes html, ">#{kind}<", "missing legend chip for #{kind}"
    end
  end
end
