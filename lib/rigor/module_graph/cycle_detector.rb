# frozen_string_literal: true

require "set"

module Rigor
  module ModuleGraph
    # Finds dependency cycles in an Edge list.
    #
    # Tarjan's strongly-connected-components, sized ≥ 2 (a SCC of
    # 1 is a single node with no self-loop and represents no cycle).
    # We also surface single-node self-loops if any edge points a
    # constant at itself.
    #
    # Returns an array of Cycle, where each Cycle carries the list
    # of node names in the cycle in a canonical rotation: smallest
    # name first. The actual edge instances making up each cycle
    # are not surfaced — for visualisation we only need the node
    # set — but a kind filter is offered so callers can ask "do
    # these edges form a cycle using only `include` / `inherits`?"
    module CycleDetector
      module_function

      Cycle = Data.define(:nodes) do
        def to_s
          nodes.join(" -> ") + " -> " + nodes.first
        end
      end

      # @param edges [Array<Edge>]
      # @param kinds [Array<String>, nil] when given, only edges
      #   whose `kind` is in the list participate in cycle detection.
      def detect(edges, kinds: nil)
        graph = build_adjacency(edges, kinds)
        sccs = tarjan(graph)
        cycles = sccs.select { |scc| scc.size >= 2 }.map { |scc| canonicalize(scc, graph) }
        self_loops = collect_self_loops(graph)
        (cycles + self_loops).sort_by { |c| c.nodes.first }
      end

      def build_adjacency(edges, kinds)
        graph = Hash.new { |h, k| h[k] = [] }
        edges.each do |edge|
          next if kinds && !kinds.include?(edge.kind)

          graph[edge.from] << edge.to
          graph[edge.to] # ensure target appears even with no outgoing edges
        end
        graph.each_value(&:uniq!)
        graph
      end

      # Iterative Tarjan to avoid blowing the Ruby stack on a wide
      # graph. Returns SCCs as arrays of node names.
      def tarjan(graph)
        index = 0
        indices = {}
        lowlink = {}
        on_stack = {}
        stack = []
        sccs = []

        graph.each_key do |start|
          next if indices.key?(start)

          work = [[start, 0]]
          indices[start] = index
          lowlink[start] = index
          index += 1
          stack.push(start)
          on_stack[start] = true

          until work.empty?
            node, i = work.last
            neighbours = graph[node]
            if i < neighbours.size
              work[-1] = [node, i + 1]
              succ = neighbours[i]
              if !indices.key?(succ)
                indices[succ] = index
                lowlink[succ] = index
                index += 1
                stack.push(succ)
                on_stack[succ] = true
                work.push([succ, 0])
              elsif on_stack[succ]
                lowlink[node] = [lowlink[node], indices[succ]].min
              end
            else
              if lowlink[node] == indices[node]
                scc = []
                loop do
                  w = stack.pop
                  on_stack.delete(w)
                  scc << w
                  break if w == node
                end
                sccs << scc
              end
              work.pop
              parent = work.last && work.last.first
              lowlink[parent] = [lowlink[parent], lowlink[node]].min if parent
            end
          end
        end
        sccs
      end

      def canonicalize(scc, graph)
        nodes = walk_cycle(scc, graph)
        nodes = rotate_to_smallest(nodes)
        Cycle.new(nodes: nodes)
      end

      # Walk a single trip around the SCC starting from its
      # smallest-named node, following outgoing edges that stay
      # in the SCC. Falls back to sorted membership if the cycle
      # is degenerate (should not happen for a real SCC ≥ 2).
      def walk_cycle(scc, graph)
        set = scc.to_set
        start = scc.min
        path = [start]
        current = start
        loop do
          next_node = graph[current].find { |n| set.include?(n) && !path.include?(n) }
          break unless next_node

          path << next_node
          current = next_node
        end
        # If we couldn't visit everyone (rare: SCC with parallel
        # branches), fall back to sorted order so output stays
        # deterministic.
        path.size == scc.size ? path : scc.sort
      end

      def rotate_to_smallest(nodes)
        i = nodes.each_with_index.min_by { |name, _| name }[1]
        nodes.rotate(i)
      end

      def collect_self_loops(graph)
        graph.each_with_object([]) do |(node, targets), acc|
          acc << Cycle.new(nodes: [node]) if targets.include?(node)
        end
      end
    end
  end
end
