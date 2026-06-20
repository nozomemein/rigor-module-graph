# frozen_string_literal: true

module Rigor
  module ModuleGraph
    # Renders an array of Edges as a Graphviz DOT document.
    #
    # Style decisions (per docs/plan.md "グラフモデル"):
    # - rankdir=LR for readability of inheritance towers
    # - inherits: thick solid
    # - include: solid
    # - prepend: solid, distinct color
    # - extend: dashed
    # - const_ref: faded dotted
    #
    # When `collapse:` is given, every node whose fully-qualified
    # name sits under one of the listed prefixes is wrapped in a
    # `subgraph cluster_<prefix>` block, and the prefix is stripped
    # from the visible label. Edges across clusters render normally;
    # Graphviz routes them between the cluster boundaries.
    module Dot
      module_function

      KIND_STYLE = {
        "inherits" => 'color="#0f172a", penwidth=2.0',
        "include" => 'color="#1d4ed8"',
        "prepend" => 'color="#9333ea"',
        "extend" => 'color="#0f766e", style="dashed"',
        "const_ref" => 'color="#94a3b8", style="dotted"'
      }.freeze

      CONFIDENCE_STYLE = {
        "unresolved" => 'style="dashed", color="#94a3b8"'
      }.freeze

      HEADER = <<~DOT
        digraph ruby_modules {
          rankdir=LR;
          graph [compound=true, overlap=false, splines=true];
          node [shape=box, style="rounded,filled", fillcolor="#f8fafc", color="#94a3b8", fontname="Helvetica"];
          edge [color="#64748b", arrowsize=0.7, fontname="Helvetica"];
      DOT

      # @param edges [Array<Edge>]
      # @param collapse [Array<String>] namespace prefixes to
      #   fold into clusters (mutually exclusive with +groups+)
      # @param groups [Hash{String=>String}, nil] explicit
      #   +{node_name => cluster_label}+ mapping. Takes precedence
      #   over +collapse+ when given. Used by the +--package+
      #   overlay where the cluster boundary is something other
      #   than a +::+ namespace prefix.
      def render(edges, collapse: [], groups: nil)
        edges = dedup(edges)
        nodes = collect_nodes(edges)
        clusters, ungrouped = build_groups(nodes, collapse, groups)

        out = +HEADER
        clusters.each do |label, members|
          out << render_cluster(label, members, use_namespace_prefix: groups.nil?)
        end
        ungrouped.each do |name|
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

      # Build the cluster partition. When +groups+ is given we
      # use it verbatim; otherwise fall back to prefix-matching
      # against +collapse+ (the legacy namespace-collapse path).
      def build_groups(nodes, collapse, groups)
        if groups && !groups.empty?
          clusters = Hash.new { |h, k| h[k] = [] }
          ungrouped = []
          nodes.each do |name|
            if (label = groups[name])
              clusters[label] << name
            else
              ungrouped << name
            end
          end
          [clusters, ungrouped]
        else
          group_by_prefix(nodes, collapse)
        end
      end

      def group_by_prefix(nodes, collapse)
        prefixes = Array(collapse).map(&:to_s).reject(&:empty?)
        return [{}, nodes] if prefixes.empty?

        sorted = prefixes.sort_by { |p| -p.length }
        clusters = Hash.new { |h, k| h[k] = [] }
        ungrouped = []
        nodes.each do |name|
          match = sorted.find { |p| name.start_with?(p + "::") }
          if match
            clusters[match] << name
          else
            ungrouped << name
          end
        end
        [clusters, ungrouped]
      end

      def render_cluster(label, members, use_namespace_prefix: true)
        out = +"  subgraph #{quote("cluster_" + cluster_id(label))} {\n"
        out << "    label=#{quote(label)};\n"
        out << "    style=\"rounded,filled\";\n"
        out << "    color=\"#cbd5e1\";\n"
        out << "    fillcolor=\"#f1f5f9\";\n"
        members.each do |name|
          short = use_namespace_prefix ? name.sub(/\A#{Regexp.escape(label)}::/, "") : name
          out << "    #{quote(name)} [label=#{quote(short)}];\n"
        end
        out << "  }\n"
      end

      # Cluster identifiers in DOT must match `[A-Za-z_][A-Za-z0-9_]*`
      # — package names like `packages/billing` would otherwise
      # break Graphviz's parser even inside quotes. Squash every
      # non-id character to `_` so the prefix `cluster_` still
      # triggers Graphviz's cluster handling.
      def cluster_id(prefix)
        prefix.gsub(/[^A-Za-z0-9_]+/, "_")
      end

      def render_edge(edge)
        attrs = +"label=\"#{edge.kind}\""
        if (style = KIND_STYLE[edge.kind])
          attrs << ", " << style
        end
        if (style = CONFIDENCE_STYLE[edge.confidence])
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
