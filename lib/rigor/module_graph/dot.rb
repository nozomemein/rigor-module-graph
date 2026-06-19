# frozen_string_literal: true

module Rigor
  module ModuleGraph
    # Renders an array of Edges as a Graphviz DOT document.
    #
    # Style decisions (per plan.md "グラフモデル"):
    # - rankdir=LR for readability of inheritance towers
    # - inherits: thick solid
    # - include: solid
    # - prepend: solid, distinct color
    # - extend: dashed
    # - const_ref: faded dotted
    module Dot
      module_function

      KIND_STYLE = {
        "inherits" => 'color="#0f172a", penwidth=2.0',
        "include" => 'color="#1d4ed8"',
        "prepend" => 'color="#9333ea"',
        "extend" => 'color="#0f766e", style="dashed"',
        "const_ref" => 'color="#94a3b8", style="dotted"'
      }.freeze

      HEADER = <<~DOT
        digraph ruby_modules {
          rankdir=LR;
          graph [compound=true, overlap=false, splines=true];
          node [shape=box, style="rounded,filled", fillcolor="#f8fafc", color="#94a3b8", fontname="Helvetica"];
          edge [color="#64748b", arrowsize=0.7, fontname="Helvetica"];
      DOT

      def render(edges)
        edges = dedup(edges)
        nodes = collect_nodes(edges)

        out = +HEADER
        nodes.each do |name|
          out << "  #{quote(name)};\n"
        end
        out << "\n" unless nodes.empty?
        edges.each do |edge|
          out << render_edge(edge)
        end
        out << "}\n"
      end

      def dedup(edges)
        seen = {}
        edges.each_with_object([]) do |edge, acc|
          key = edge.dedup_key
          next if seen[key]

          seen[key] = true
          acc << edge
        end
      end

      def collect_nodes(edges)
        names = edges.flat_map { |edge| [edge.from, edge.to] }
        names.uniq.sort
      end

      def render_edge(edge)
        attrs = +"label=\"#{edge.kind}\""
        if (style = KIND_STYLE[edge.kind])
          attrs << ", " << style
        end
        "  #{quote(edge.from)} -> #{quote(edge.to)} [#{attrs}];\n"
      end

      def quote(name)
        # DOT identifiers that contain `::` or quotes must be
        # double-quoted; escape embedded double quotes.
        '"' + name.gsub('"', '\"') + '"'
      end
    end
  end
end
