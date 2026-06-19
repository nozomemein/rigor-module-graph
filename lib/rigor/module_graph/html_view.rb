# frozen_string_literal: true

require "erb"

module Rigor
  module ModuleGraph
    # Self-contained HTML document that embeds Mermaid output
    # inline so it renders without any local server (works over
    # +file://+, no fetch).
    #
    # The view loads +mermaid@10+ from a CDN at render time. The
    # only network access is that one CDN URL; if a project needs
    # to ship a fully offline page, render the SVG via Graphviz
    # and embed that instead.
    module HtmlView
      module_function

      # @param title [String] page <title> and <h1> text
      # @param mermaid_source [String] the mermaid flowchart body
      # @param subtitle [String, nil] one-line caption under the H1
      # @return [String] the rendered HTML document
      def render(title:, mermaid_source:, subtitle: nil)
        indented = mermaid_source.strip.gsub("\n", "\n  ")
        ERB.new(TEMPLATE, trim_mode: "-").result_with_hash(
          title: title,
          subtitle: subtitle,
          indented_mermaid: indented
        )
      end

      TEMPLATE = <<~ERB
        <!doctype html>
        <html lang="en">
          <head>
            <meta charset="utf-8">
            <title><%= title %></title>
            <script type="module">
              import mermaid from "https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.esm.min.mjs";
              mermaid.initialize({ startOnLoad: true, securityLevel: "loose" });
            </script>
            <style>
              body { font: 14px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; margin: 2rem; color: #0f172a; background: #f8fafc; }
              h1 { margin-top: 0; }
              .meta { color: #64748b; margin-bottom: 1.5rem; }
              .card { background: white; border: 1px solid #e2e8f0; border-radius: 8px; padding: 1.5rem; box-shadow: 0 1px 2px rgba(15,23,42,0.04); }
              .legend { display: flex; gap: 1rem; flex-wrap: wrap; margin-top: 1rem; }
              .legend span { padding: 0.25rem 0.75rem; border-radius: 999px; color: white; font-size: 12px; }
              .legend .inherits { background: #0f172a; }
              .legend .include { background: #1d4ed8; }
              .legend .prepend { background: #9333ea; }
              .legend .extend { background: #0f766e; }
              .legend .const_ref { background: #94a3b8; color: #0f172a; }
              .legend .unresolved { background: #fef3c7; color: #0f172a; }
            </style>
          </head>
          <body>
            <h1><%= title %></h1>
            <% if subtitle -%>
              <p class="meta"><%= subtitle %></p>
            <% end -%>
            <div class="card">
              <pre class="mermaid">
        <%= indented_mermaid %>
              </pre>
            </div>
            <div class="legend">
              <span class="inherits">inherits</span>
              <span class="include">include</span>
              <span class="prepend">prepend</span>
              <span class="extend">extend</span>
              <span class="const_ref">const_ref</span>
              <span class="unresolved">unresolved</span>
            </div>
          </body>
        </html>
      ERB
    end
  end
end
