# frozen_string_literal: true

require "erb"
require "json"

module Rigor
  module ModuleGraph
    # Interactive viewer that replaces the static-Mermaid HTML
    # for `view --output html`. The output is a self-contained
    # HTML file: vendored `cytoscape.min.js` is inlined alongside
    # our ~100-line init script and the node / edge dataset, so
    # the artefact opens in any browser without a network round
    # trip. See `docs/plan.md` "2D interactive viewer" for the
    # supply-chain rationale.
    module Viewer
      module Html
        module_function

        TEMPLATE_DIR = File.expand_path("../templates", __dir__)
        TEMPLATE_PATH = File.join(TEMPLATE_DIR, "viewer.html.erb")
        CSS_PATH = File.join(TEMPLATE_DIR, "viewer.css")
        VIEWER_JS_PATH = File.join(TEMPLATE_DIR, "viewer.js")
        CYTOSCAPE_JS_PATH = File.join(TEMPLATE_DIR, "vendor", "cytoscape.min.js")

        # Node kinds that map to top-level Cytoscape nodes.
        # Method / attribute nodes are out of scope for the graph
        # viewer (they belong to the class diagram, not the
        # dependency graph).
        CONSTANT_KINDS = %w[class module].freeze

        # @param edges [Array<Edge>] dependency edges
        # @param nodes [Array<Node>] node metadata (for click-through)
        # @param title [String] page title
        # @param subtitle [String, nil] optional subtitle line
        # @param path_mode [:relative, :absolute, :none]
        #   how `data.path` is reported to click handlers. `:none`
        #   strips it entirely so HTML shared externally doesn't
        #   leak filesystem layout.
        # @param open_with [Symbol, nil] when `:vscode`, node click
        #   opens `vscode://file/<path>:<line>` instead of writing
        #   to clipboard.
        # @return [String] complete HTML document
        def render(edges:, nodes:, title:, subtitle: nil, path_mode: :relative, open_with: nil)
          data = build_data(
            edges: edges, nodes: nodes,
            path_mode: path_mode, open_with: open_with
          )
          template = ERB.new(File.read(TEMPLATE_PATH), trim_mode: "-")
          template.result_with_hash(
            title: title,
            subtitle: subtitle,
            data_json: safe_json(data),
            css: File.read(CSS_PATH),
            cytoscape: File.read(CYTOSCAPE_JS_PATH),
            viewer: File.read(VIEWER_JS_PATH)
          )
        end

        # Builds the `{nodes:, edges:, options:}` payload the
        # inline init JS reads from
        # `<script type="application/json" id="rmg-data">`.
        def build_data(edges:, nodes:, path_mode:, open_with:)
          node_meta = {}
          nodes.each do |node|
            next unless CONSTANT_KINDS.include?(node.kind)

            key = fully_qualified(node)
            # First definition wins; class re-opens still resolve
            # to one Cytoscape node, matching the dedup contract
            # in `Edge#dedup_key`.
            node_meta[key] ||= {
              # Cytoscape resolves `edge.source` / `edge.target`
              # against `node.data.id`, so the constant name has
              # to be the id (not just a display field).
              id: key,
              name: key,
              kind: node.kind,
              path: path_for(node.path, path_mode),
              line: node.line
            }
          end

          # Every edge endpoint becomes a node, even when the
          # constant has no definition in the analysed paths
          # (e.g. `ApplicationRecord` from a Rails gem). These
          # get the `external` kind so the styling can dim them.
          edges.flat_map { |e| [e.from, e.to] }.uniq.each do |name|
            node_meta[name] ||= { id: name, name: name, kind: "external" }
          end

          {
            nodes: node_meta.values.map { |n| { data: n } },
            edges: edges.each_with_index.map do |edge, i|
              {
                data: {
                  id: "e#{i}",
                  source: edge.from,
                  target: edge.to,
                  kind: edge.kind,
                  confidence: edge.confidence
                }
              }
            end,
            options: { open_with: open_with&.to_s }
          }
        end

        def fully_qualified(node)
          owner = node.owner
          owner && !owner.empty? ? "#{owner}::#{node.name}" : node.name
        end

        def path_for(path, mode)
          return nil if path.nil? || mode == :none

          case mode
          when :absolute then File.expand_path(path)
          when :relative then path
          end
        end

        # JSON embedded in `<script>` must not contain `</` (would
        # break out of the surrounding tag). `JSON.generate` does
        # not escape it by default; rewriting the literal pair
        # `</` → `<\/` is the standard safety pass.
        def safe_json(value)
          JSON.generate(value).gsub("</", "<\\/")
        end
      end
    end
  end
end
