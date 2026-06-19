# frozen_string_literal: true

module Rigor
  module ModuleGraph
    # Renders edges as a Mermaid flowchart.
    #
    # Mermaid does not have per-edge style classes the way DOT does;
    # we use distinct arrow heads per kind (`==>`, `-->`, `-.->`)
    # plus an `:::kind` classDef on the target node so the legend is
    # readable in any Mermaid renderer.
    module Mermaid
      module_function

      ARROW_FOR_KIND = {
        "inherits" => "==>",
        "include" => "-->",
        "prepend" => "-->",
        "extend" => "-.->",
        "const_ref" => "-.->"
      }.freeze

      CLASS_DEFS = <<~MERMAID
        classDef inherits fill:#0f172a,color:#fff,stroke:#0f172a;
        classDef include fill:#1d4ed8,color:#fff,stroke:#1d4ed8;
        classDef prepend fill:#9333ea,color:#fff,stroke:#9333ea;
        classDef extend fill:#0f766e,color:#fff,stroke:#0f766e;
        classDef const_ref fill:#cbd5e1,color:#0f172a,stroke:#94a3b8;
      MERMAID

      def render(edges)
        edges = dedup(edges)
        node_ids = assign_node_ids(edges)
        out = +"flowchart LR\n"
        node_ids.each do |name, id|
          out << "  #{id}[\"#{escape_label(name)}\"]\n"
        end
        out << "\n" unless node_ids.empty?
        edges.each do |edge|
          arrow = ARROW_FOR_KIND.fetch(edge.kind, "-->")
          out << "  #{node_ids[edge.from]} #{arrow}|#{edge.kind}| #{node_ids[edge.to]}\n"
        end
        out << "\n"
        out << CLASS_DEFS
        edges.each do |edge|
          out << "  class #{node_ids[edge.to]} #{edge.kind};\n"
        end
        out
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

      def assign_node_ids(edges)
        names = edges.flat_map { |edge| [edge.from, edge.to] }.uniq.sort
        names.each_with_index.to_h { |name, idx| [name, "n#{idx}"] }
      end

      def escape_label(name)
        name.gsub('"', '#quot;')
      end
    end
  end
end
