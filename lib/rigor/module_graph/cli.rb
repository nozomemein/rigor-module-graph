# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "optparse"
require "set"
require "shellwords"

require_relative "edge"
require_relative "node"
require_relative "dot"
require_relative "mermaid"
require_relative "cycle_detector"
require_relative "reachability"
require_relative "stats"
require_relative "packwerk_overlay"
require_relative "html_view"
require_relative "status_reporter"
require_relative "uml/class_diagram"
require_relative "viewer/html"

module Rigor
  module ModuleGraph
    # Entry point for the `rigor-module-graph` executable.
    #
    # Subcommands:
    #
    #   collect [PATHS...]   Run `rigor check` and write edges JSONL
    #   dot     [FILE]       Render edges JSONL as Graphviz DOT
    #   mermaid [FILE]       Render edges JSONL as Mermaid
    #   cycles  [FILE]       Detect cycles and print them
    #
    # Every reader subcommand takes the path to an edges file, or
    # reads stdin if no path is given. Each reader supports
    # `--kind` and `--confidence` filters so a noisy graph can be
    # pruned without touching the JSONL on disk.
    module CLI
      DEFAULT_EDGES_PATH = ".rigor/module_graph/edges.jsonl"
      DEFAULT_NODES_PATH = ".rigor/module_graph/nodes.jsonl"
      SOURCE_FAMILY = "plugin.module-graph"
      EDGE_RULE = "edge"
      NODE_RULE = "node"

      module_function

      def run(argv, stdout: $stdout, stderr: $stderr, stdin: $stdin)
        argv = argv.dup
        command = argv.shift
        case command
        when nil
          View.new(stdout: stdout, stderr: stderr).run([])
        when "view"
          View.new(stdout: stdout, stderr: stderr).run(argv)
        when "collect"
          Collect.new(stdout: stdout, stderr: stderr).run(argv)
        when "dot"
          Render.new(:dot, stdout: stdout, stderr: stderr, stdin: stdin).run(argv)
        when "mermaid"
          Render.new(:mermaid, stdout: stdout, stderr: stderr, stdin: stdin).run(argv)
        when "cycles"
          Cycles.new(stdout: stdout, stderr: stderr, stdin: stdin).run(argv)
        when "stats"
          StatsCmd.new(stdout: stdout, stderr: stderr, stdin: stdin).run(argv)
        when "class-diagram"
          ClassDiagramCmd.new(stdout: stdout, stderr: stderr, stdin: stdin).run(argv)
        when "-h", "--help", "help"
          stdout.puts USAGE
          0
        when "version", "-v", "--version"
          stdout.puts "rigor-module-graph #{Rigor::ModuleGraph::VERSION}"
          0
        else
          stderr.puts "rigor-module-graph: unknown command #{command.inspect}"
          stderr.puts USAGE
          2
        end
      end

      USAGE = <<~USAGE
        Usage: rigor-module-graph [command] [options] [paths]

        Default (no command): same as `view` — analyse the current
        directory, write an HTML report, and open it in a browser.

        Commands:
          view          [PATHS...]   Analyse, write HTML, open in a browser
          collect       [PATHS...]   Run `rigor check` and write edges + nodes JSONL
          dot           [FILE]       Render edges JSONL as Graphviz DOT
          mermaid       [FILE]       Render edges JSONL as Mermaid flowchart
          class-diagram [FILE]       Render edges + nodes as Mermaid classDiagram (UML)
          cycles        [FILE]       Detect cycles in edges JSONL
          stats         [FILE]       Per-namespace fan-in / fan-out report

        Run `rigor-module-graph <command> --help` for command-specific options.
      USAGE

      # Shared filter options reused by dot / mermaid / cycles / view.
      module EdgeFilters
        VALID_KINDS = Rigor::ModuleGraph::EDGE_KINDS
        VALID_CONFIDENCES = Rigor::ModuleGraph::EDGE_CONFIDENCES
        VALID_DIRECTIONS = Reachability::VALID_DIRECTIONS
        VALID_EDGE_SCOPES = Reachability::VALID_EDGE_SCOPES

        def apply_filters(edges, kinds:, confidences:, from: nil, depth: nil,
                          direction: :both, edge_scope: :cluster)
          edges = edges.select { |e| kinds.include?(e.kind) } if kinds
          edges = edges.select { |e| confidences.include?(e.confidence) } if confidences
          if from && !from.empty?
            edges = Reachability.filter(
              edges, roots: from, depth: depth, direction: direction, edge_scope: edge_scope
            )
          end
          edges
        end

        def add_filter_options(opts, state)
          opts.on("--kind KINDS", Array,
                  "Only render the listed edge kinds (#{VALID_KINDS.join(",")})") do |list|
            state[:kinds] = validate!(list, VALID_KINDS, "kind")
          end
          opts.on("--confidence LEVELS", Array,
                  "Only render the listed confidence levels (#{VALID_CONFIDENCES.join(",")})") do |list|
            state[:confidences] = validate!(list, VALID_CONFIDENCES, "confidence")
          end
          opts.on("--from NAMES", Array,
                  "Restrict the graph to nodes reachable from NAMES (comma-separated)") do |names|
            state[:from] = names
          end
          opts.on("--depth N", Integer,
                  "Maximum hops from --from roots (default: unlimited)") do |n|
            state[:depth] = n
          end
          opts.on("--direction DIR", VALID_DIRECTIONS.map(&:to_s),
                  "Direction to follow from --from roots (#{VALID_DIRECTIONS.join(", ")}; default: both)") do |dir|
            state[:direction] = dir.to_sym
          end
          opts.on("--edge-scope SCOPE", VALID_EDGE_SCOPES.map(&:to_s),
                  "Edges to keep when --from is set: cluster keeps every edge whose " \
                  "endpoints both fall in the reachable node set; walk keeps only " \
                  "the edges the BFS actually traverses " \
                  "(#{VALID_EDGE_SCOPES.join("|")}; default: cluster)") do |scope|
            state[:edge_scope] = scope.to_sym
          end
        end

        def validate!(list, allowed, label)
          unknown = list - allowed
          unless unknown.empty?
            raise OptionParser::InvalidArgument,
                  "unknown #{label}(s): #{unknown.join(",")}. Allowed: #{allowed.join(",")}"
          end
          list
        end
      end

      # Encapsulates the actual `rigor check --format json` shell-out
      # and the diagnostic → Edge / Node transformation. Reused by
      # both `Collect` (write JSONL) and `View` (render HTML).
      class RigorRunner
        def initialize(rigor_cmd: ENV.fetch("RIGOR_CMD", "rigor"), cache: false)
          @rigor_cmd = rigor_cmd
          @cache = cache
        end

        def edges_for(paths)
          diagnostics = run_rigor(paths)
          diagnostics_to_edges(diagnostics)
        end

        # Returns both edges and nodes from one rigor invocation.
        def analyse(paths)
          diagnostics = run_rigor(paths)
          [diagnostics_to_edges(diagnostics), diagnostics_to_nodes(diagnostics)]
        end

        def run_rigor(paths)
          cmd = [@rigor_cmd, "check", "--format", "json"]
          cmd << (@cache ? "--cache" : "--no-cache")
          cmd << "--no-stats"
          cmd.concat(paths) unless paths.empty?

          stdout_str, stderr_str, status = Open3.capture3(*cmd)
          unless status.success?
            # `rigor check` exits non-zero when it finds any error
            # diagnostic — our edges live inside that same output,
            # so we still parse the JSON. We only escalate when no
            # JSON was emitted at all (e.g. binary missing).
            if stdout_str.empty?
              raise CollectError, "rigor exited #{status.exitstatus} with no output\n#{stderr_str}"
            end
          end
          payload = JSON.parse(stdout_str)
          payload.fetch("diagnostics", [])
        rescue Errno::ENOENT
          raise CollectError, "rigor binary not found: #{cmd.first.inspect}. " \
                              "Install rigortype or set RIGOR_CMD."
        rescue JSON::ParserError => e
          raise CollectError, "rigor produced invalid JSON: #{e.message}\n#{stdout_str}"
        end

        def diagnostics_to_edges(diagnostics)
          diagnostics.filter_map do |row|
            next unless row["rule"] == EDGE_RULE
            next unless row["source_family"] == SOURCE_FAMILY

            payload = JSON.parse(row.fetch("message"))
            Edge.build(
              from: payload.fetch("from"),
              to: payload.fetch("to"),
              kind: payload.fetch("kind"),
              path: row["path"],
              line: row["line"],
              column: row["column"],
              confidence: payload.fetch("confidence", "syntax"),
              raw: payload["raw"]
            )
          rescue JSON::ParserError, KeyError
            nil
          end
        end

        def diagnostics_to_nodes(diagnostics)
          diagnostics.filter_map do |row|
            next unless row["rule"] == NODE_RULE
            next unless row["source_family"] == SOURCE_FAMILY

            payload = JSON.parse(row.fetch("message"))
            Node.build(
              kind: payload.fetch("kind"),
              name: payload.fetch("name"),
              owner: payload["owner"],
              path: row["path"],
              line: row["line"],
              column: row["column"],
              visibility: payload["visibility"],
              access: payload["access"]
            )
          rescue JSON::ParserError, KeyError
            nil
          end
        end
      end

      class CollectError < StandardError; end

      # `collect` shells out to `rigor check --format json` and
      # writes a JSONL edge file by filtering the diagnostics for
      # our `source_family` + `rule`.
      class Collect
        DEFAULT_PATHS = [].freeze

        def initialize(stdout:, stderr:)
          @stdout = stdout
          @stderr = stderr
          @options = {
            output: DEFAULT_EDGES_PATH,
            nodes_output: DEFAULT_NODES_PATH,
            cache: false,
            quiet: false,
            rigor_cmd: ENV.fetch("RIGOR_CMD", "rigor")
          }
        end

        def run(argv)
          parser = build_parser
          paths = parser.parse(argv)

          status = Rigor::ModuleGraph::StatusReporter.new(stderr: @stderr, quiet: @options[:quiet])

          ensure_output_dirs
          runner = RigorRunner.new(rigor_cmd: @options[:rigor_cmd], cache: @options[:cache])
          edges, nodes = status.step(rigor_step_label(paths)) { runner.analyse(paths) }
          status.info "#{edges.size} edge(s), #{nodes.size} node(s)"
          status.step("Writing #{@options[:output]}") { write_edges(edges) }
          status.step("Writing #{@options[:nodes_output]}") { write_nodes(nodes) }

          @stderr.puts "rigor-module-graph: wrote #{edges.size} edge(s) to #{@options[:output]}, " \
                       "#{nodes.size} node(s) to #{@options[:nodes_output]}"
          0
        rescue OptionParser::ParseError => e
          @stderr.puts "rigor-module-graph collect: #{e.message}"
          2
        rescue CollectError => e
          @stderr.puts "rigor-module-graph collect: #{e.message}"
          1
        end

        # Path-aware label so the user can see which paths Rigor
        # is being pointed at when the step is slow.
        def rigor_step_label(paths)
          target = paths.empty? ? "configured paths" : paths.join(", ")
          "Running rigor check on #{target}"
        end

        def build_parser
          OptionParser.new do |opts|
            opts.banner = "Usage: rigor-module-graph collect [options] [PATHS...]"
            opts.on("-o", "--output PATH",
                    "Write edges to PATH (default: #{DEFAULT_EDGES_PATH})") do |path|
              @options[:output] = path
            end
            opts.on("--nodes-output PATH",
                    "Write nodes to PATH (default: #{DEFAULT_NODES_PATH})") do |path|
              @options[:nodes_output] = path
            end
            opts.on("--[no-]cache",
                    "Pass `--cache` / `--no-cache` to rigor (default: --no-cache)") do |cache|
              @options[:cache] = cache
            end
            opts.on("--rigor-cmd CMD",
                    "Override the rigor binary (default: rigor or $RIGOR_CMD)") do |cmd|
              @options[:rigor_cmd] = cmd
            end
            opts.on("-q", "--quiet", "Suppress step-level progress on stderr") do
              @options[:quiet] = true
            end
            opts.on("-h", "--help") do
              @stdout.puts opts
              exit 0
            end
          end
        end

        def ensure_output_dirs
          [@options[:output], @options[:nodes_output]].each do |path|
            dir = File.dirname(path)
            FileUtils.mkdir_p(dir) unless dir.empty?
          end
        end

        def write_edges(edges)
          File.open(@options[:output], "w") do |io|
            EdgeIO.write(edges, io)
          end
        end

        def write_nodes(nodes)
          File.open(@options[:nodes_output], "w") do |io|
            NodeIO.write(nodes, io)
          end
        end
      end

      # `view` is the one-shot entry point: from the project root
      # type `rigor-module-graph` and it analyses the current
      # directory, writes a self-contained Mermaid HTML report,
      # and opens it in a browser.
      #
      # Defaults are tuned to need zero flags on a Rails-shaped
      # project. The lower-level subcommands (collect / dot /
      # mermaid) stay available for piped use.
      class View
        include EdgeFilters

        DEFAULT_OUTPUT = ".rigor/module_graph/view.html"
        # An auto-collapsed cluster needs at least this many
        # members before it's worth folding. Three is the sweet
        # spot empirically: a 1500-edge Rails app collapses into
        # roughly the right shape, and a small fixture still
        # leaves trivial Foo / Bar pairs uncollapsed.
        AUTO_COLLAPSE_THRESHOLD = 3
        # Cap the visible "collapsed: …" trailer in the subtitle
        # so it doesn't grow into an unreadable wall on large
        # projects.
        SUBTITLE_COLLAPSE_PREVIEW = 6

        # The supported output formats, in roughly increasing
        # "wrapping" order. `html` is the interactive Cytoscape
        # viewer (vendored, self-contained); `mermaid-html` is
        # the older static-Mermaid-via-CDN page kept for
        # backwards compatibility; `svg` embeds the dot layout;
        # the rest are raw text.
        FORMATS = %w[html mermaid-html mermaid dot svg class-diagram].freeze

        # `--path-mode` controls how the click-through metadata
        # `data.path` is reported on every node. See
        # `Viewer::Html#path_for` for what each mode emits.
        PATH_MODES = %i[relative absolute none].freeze

        # `--open-with` flips the node-click action from
        # clipboard copy to opening the file in an editor via
        # a custom URL scheme. `vscode` is the only supported
        # editor today.
        OPEN_WITH = %i[vscode].freeze

        # Default file destination when format is html and the
        # user didn't override with -o. Non-html formats default to
        # stdout.
        DEFAULT_HTML_OUTPUT = ".rigor/module_graph/view.html"

        def initialize(stdout:, stderr:)
          @stdout = stdout
          @stderr = stderr
          @options = {
            format: "html",
            output: nil,
            cache: false,
            quiet: false,
            rigor_cmd: ENV.fetch("RIGOR_CMD", "rigor"),
            open: true,
            collapse: nil,
            kinds: nil,
            confidences: nil,
            from: nil,
            depth: nil,
            direction: :both,
            edge_scope: :cluster,
            package: nil,
            include_methods: true,
            include_attributes: true,
            visibilities: %w[public protected private],
            path_mode: :relative,
            open_with: nil
          }
        end

        def run(argv)
          parser = build_parser
          paths = parser.parse(argv)

          status = Rigor::ModuleGraph::StatusReporter.new(stderr: @stderr, quiet: @options[:quiet])

          runner = RigorRunner.new(rigor_cmd: @options[:rigor_cmd], cache: @options[:cache])
          edges, nodes = status.step(rigor_step_label(paths)) { runner.analyse(paths) }
          status.info "#{edges.size} edge(s), #{nodes.size} node(s)"

          if any_filter_active?
            edges = status.step("Applying filters") do
              apply_filters(
                edges,
                kinds: @options[:kinds],
                confidences: @options[:confidences],
                from: @options[:from],
                depth: @options[:depth],
                direction: @options[:direction],
                edge_scope: @options[:edge_scope]
              )
            end
            status.info "#{edges.size} edge(s) after filters"
          end

          groups = package_groups(edges)
          collapse = groups ? [] : effective_collapse(edges)

          payload, binary = status.step("Rendering #{@options[:format]}") do
            render_payload(edges, nodes, collapse, groups)
          end
          deliver(payload, binary: binary, edges: edges, status: status)
          0
        rescue OptionParser::ParseError => e
          @stderr.puts "rigor-module-graph view: #{e.message}"
          2
        rescue CollectError, RenderError => e
          @stderr.puts "rigor-module-graph view: #{e.message}"
          1
        end

        def rigor_step_label(paths)
          target = paths.empty? ? "configured paths" : paths.join(", ")
          "Running rigor check on #{target}"
        end

        def any_filter_active?
          @options[:kinds] || @options[:confidences] ||
            @options[:from] || @options[:depth]
        end

        def silent_status
          Rigor::ModuleGraph::StatusReporter.new(stderr: @stderr, quiet: true)
        end

        class RenderError < StandardError; end

        # Builds the rendered payload for the chosen format and
        # signals whether the bytes are binary (svg via Graphviz
        # can return a non-UTF-8 image stream).
        def render_payload(edges, nodes, collapse, groups)
          case @options[:format]
          when "html"
            html = Viewer::Html.render(
              edges: edges,
              nodes: restrict_nodes_to_edges(nodes, edges),
              title: "rigor-module-graph: #{File.basename(Dir.pwd)}",
              subtitle: render_subtitle(edges, collapse, groups),
              path_mode: @options[:path_mode],
              open_with: @options[:open_with]
            )
            [html, false]
          when "mermaid-html"
            mermaid = Mermaid.render(edges, collapse: collapse, groups: groups)
            html = HtmlView.render(
              title: "rigor-module-graph: #{File.basename(Dir.pwd)}",
              subtitle: render_subtitle(edges, collapse, groups),
              mermaid_source: mermaid
            )
            [html, false]
          when "mermaid"
            [Mermaid.render(edges, collapse: collapse, groups: groups), false]
          when "dot"
            [Dot.render(edges, collapse: collapse, groups: groups), false]
          when "svg"
            [graphviz_svg(Dot.render(edges, collapse: collapse, groups: groups)), true]
          when "class-diagram"
            [
              Uml::ClassDiagram.render(
                edges, restrict_nodes_to_edges(nodes, edges),
                include_methods: @options[:include_methods],
                include_attributes: @options[:include_attributes],
                visibilities: @options[:visibilities]
              ),
              false
            ]
          end
        end

        # When the user narrows the edge set with `--from` /
        # `--kind` / `--confidence`, the class diagram should only
        # show classes that participate in those edges — otherwise
        # every constant declared in the project still shows up as
        # a body-less class. The filter is a no-op when the edge
        # set already covers every node (no filters applied).
        def restrict_nodes_to_edges(nodes, edges)
          return nodes if edges.empty?

          visible = Set.new
          edges.each { |edge| visible << edge.from << edge.to }
          nodes.select { |node| visible.include?(node.owner) || visible.include?(node.name) }
        end

        # Shell out to Graphviz `dot -Tsvg`. Surfacing the binary
        # check as a clear error keeps the message friendlier than
        # the raw `Errno::ENOENT` Open3 would propagate.
        def graphviz_svg(dot_source)
          stdout_str, stderr_str, status = Open3.capture3("dot", "-Tsvg", stdin_data: dot_source)
          unless status.success?
            raise RenderError, "graphviz `dot` failed (exit #{status.exitstatus}): #{stderr_str}"
          end

          stdout_str
        rescue Errno::ENOENT
          raise RenderError, "graphviz `dot` not found on PATH; install via " \
                             "`brew install graphviz` (macOS) or your distro's package manager"
        end

        # Writes the payload to the configured destination and
        # opens the browser when the html-default flow applies.
        # `status:` defaults to a silent reporter so the existing
        # test surface (which exercises `deliver` directly) keeps
        # working without threading a reporter through.
        def deliver(payload, binary:, edges:, status: silent_status)
          destination = effective_output_path
          if destination.nil?
            if binary
              @stdout.binmode
            end
            @stdout.write(payload)
            return
          end

          status.step("Writing #{destination}") do
            dir = File.dirname(destination)
            FileUtils.mkdir_p(dir) unless dir.empty? || dir == "."
            mode = binary ? "wb" : "w"
            File.open(destination, mode) { |io| io.write(payload) }
          end
          @stderr.puts "rigor-module-graph: wrote #{edges.size} edge(s) to #{destination}"
          return unless html? && @options[:open]

          status.step("Opening #{destination} in browser") { open_in_browser(destination) }
        end

        # Resolve the output path. `-o PATH` always wins. With no
        # explicit path, html falls back to `.rigor/module_graph/
        # view.html`; every other format streams to stdout.
        def effective_output_path
          return @options[:output] if @options[:output]
          return DEFAULT_HTML_OUTPUT if html?

          nil
        end

        def html?
          %w[html mermaid-html].include?(@options[:format])
        end

        def build_parser
          OptionParser.new do |opts|
            opts.banner = "Usage: rigor-module-graph view [options] [PATHS...]"
            opts.on("--output FORMAT", FORMATS,
                    "Output format (#{FORMATS.join("|")}; default: html). " \
                    "Non-html streams to stdout unless -o is given.") do |fmt|
              @options[:format] = fmt
            end
            opts.on("-o", "--save PATH",
                    "Write to PATH instead of stdout / the default html location") do |path|
              @options[:output] = path
            end
            opts.on("--[no-]open",
                    "Open the html in a browser (default: true; ignored for non-html)") do |flag|
              @options[:open] = flag
            end
            opts.on("--collapse PREFIXES", Array,
                    "Manual collapse list (disables auto-detection)") do |prefixes|
              @options[:collapse] = prefixes
            end
            opts.on("--no-collapse",
                    "Disable namespace collapse entirely") do
              @options[:collapse] = []
            end
            opts.on("--no-methods",
                    "[class-diagram] Don't render methods inside class bodies") do
              @options[:include_methods] = false
            end
            opts.on("--no-attributes",
                    "[class-diagram] Don't render attributes inside class bodies") do
              @options[:include_attributes] = false
            end
            opts.on("--public-only",
                    "[class-diagram] Only show public members") do
              @options[:visibilities] = %w[public]
            end
            opts.on("--no-private",
                    "[class-diagram] Hide private members") do
              @options[:visibilities] = %w[public protected]
            end
            opts.on("--package",
                    "Cluster by Packwerk packages discovered in cwd") do
              @options[:package] ||= "."
            end
            opts.on("--package-root PATH",
                    "Cluster by Packwerk packages discovered under PATH") do |root|
              @options[:package] = root
            end
            opts.on("--[no-]cache",
                    "Pass --cache / --no-cache to rigor (default: --no-cache)") do |cache|
              @options[:cache] = cache
            end
            opts.on("--rigor-cmd CMD",
                    "Override the rigor binary (default: rigor or $RIGOR_CMD)") do |cmd|
              @options[:rigor_cmd] = cmd
            end
            opts.on("-q", "--quiet", "Suppress step-level progress on stderr") do
              @options[:quiet] = true
            end
            add_viewer_options(opts)
            add_filter_options(opts, @options)
            opts.on("-h", "--help") do
              @stdout.puts opts
              exit 0
            end
          end
        end

        def add_viewer_options(opts)
          opts.on("--path-mode MODE", PATH_MODES,
                  "How to report node paths in the html viewer: " \
                  "#{PATH_MODES.join(" / ")} (default: relative). " \
                  "`none` strips path metadata entirely — useful when " \
                  "sharing the html artefact outside the project.") do |mode|
            @options[:path_mode] = mode
          end
          opts.on("--open-with EDITOR", OPEN_WITH,
                  "Make node clicks open the file in EDITOR instead of " \
                  "copying path:line to the clipboard. " \
                  "Supported: #{OPEN_WITH.join(" / ")}.") do |editor|
            @options[:open_with] = editor
          end
        end

        # Choose collapse prefixes. Explicit `--collapse` wins;
        # otherwise we auto-pick top-level namespaces that have at
        # least AUTO_COLLAPSE_THRESHOLD distinct nodes under them,
        # which is what most graphs benefit from.
        def effective_collapse(edges)
          return @options[:collapse] unless @options[:collapse].nil?

          counts = Hash.new { |h, k| h[k] = Set.new }
          edges.each do |edge|
            [edge.from, edge.to].each do |name|
              head, tail = name.split("::", 2)
              # Only collapse on the top-level segment so a deep
              # tree like `Billing::Invoice::Line` still feeds into
              # the `Billing` cluster — picking inner prefixes
              # would compete with each other and produce nested
              # clusters that hurt readability.
              next if tail.nil? || tail.empty?
              # Absolute paths (`::Foo::Bar`) split with an empty
              # head; skip them so they don't surface as the bogus
              # `""` collapse target.
              next if head.empty?

              counts[head] << name
            end
          end
          counts.select { |_, members| members.size >= AUTO_COLLAPSE_THRESHOLD }.keys.sort
        end

        def render_subtitle(edges, collapse, groups)
          parts = ["#{edges.size} edge(s) from #{Dir.pwd}"]
          if @options[:from]
            from_part = +"from: #{Array(@options[:from]).join(", ")}"
            from_part << " (depth=#{@options[:depth]})" if @options[:depth]
            from_part << " [#{@options[:direction]}]" unless @options[:direction] == :both
            parts << from_part
          end
          if groups
            uniq_packages = groups.values.uniq.sort
            preview = uniq_packages.first(SUBTITLE_COLLAPSE_PREVIEW)
            label = +"packages: #{preview.join(", ")}"
            if uniq_packages.size > preview.size
              label << " (+#{uniq_packages.size - preview.size} more)"
            end
            parts << label
          elsif !collapse.empty?
            preview = collapse.first(SUBTITLE_COLLAPSE_PREVIEW)
            label = +"collapsed: #{preview.join(", ")}"
            label << " (+#{collapse.size - preview.size} more)" if collapse.size > preview.size
            parts << label
          end
          parts.join(" · ")
        end

        def package_groups(edges)
          return nil unless @options[:package]

          overlay = PackwerkOverlay.discover(@options[:package])
          unless overlay.any?
            @stderr.puts "rigor-module-graph view: no package.yml found under " \
                         "#{@options[:package].inspect}; falling back to namespace collapse"
            return nil
          end

          overlay.groups_for(edges)
        end

        def open_in_browser(path)
          opener = ENV["BROWSER"] ||
                   (RUBY_PLATFORM.include?("darwin") ? "open" : "xdg-open")
          system(opener, path)
        rescue StandardError => e
          @stderr.puts "rigor-module-graph view: could not open #{path}: #{e.message}"
        end
      end

      # Shared base for `dot` / `mermaid` — both load an edges JSONL
      # and print a rendered string.
      class Render
        include EdgeFilters

        def initialize(format, stdout:, stderr:, stdin:)
          @format = format
          @stdout = stdout
          @stderr = stderr
          @stdin = stdin
          @state = {
            collapse: [], kinds: nil, confidences: nil,
            from: nil, depth: nil, direction: :both, edge_scope: :cluster,
            package: nil
          }
        end

        def run(argv)
          argv = argv.dup
          parse_options!(argv)
          path, = argv
          io = path ? File.open(path, "r") : @stdin
          begin
            edges = EdgeIO.read(io)
          ensure
            io.close if path && !io.closed?
          end
          edges = apply_filters(
            edges,
            kinds: @state[:kinds],
            confidences: @state[:confidences],
            from: @state[:from],
            depth: @state[:depth],
            direction: @state[:direction],
            edge_scope: @state[:edge_scope]
          )
          groups = package_groups(edges)
          @stdout.print(rendered(edges, groups))
          0
        rescue Errno::ENOENT => e
          @stderr.puts "rigor-module-graph #{@format}: #{e.message}"
          1
        rescue OptionParser::ParseError => e
          @stderr.puts "rigor-module-graph #{@format}: #{e.message}"
          2
        end

        def package_groups(edges)
          return nil unless @state[:package]

          overlay = PackwerkOverlay.discover(@state[:package])
          unless overlay.any?
            @stderr.puts "rigor-module-graph #{@format}: no package.yml found under #{@state[:package].inspect}"
            return nil
          end

          overlay.groups_for(edges)
        end

        def parse_options!(argv)
          parser = OptionParser.new do |opts|
            opts.banner = "Usage: rigor-module-graph #{@format} [options] [FILE]"
            opts.on("--collapse PREFIXES", Array,
                    "Comma-separated namespace prefixes to fold into clusters") do |prefixes|
              @state[:collapse].concat(prefixes)
            end
            opts.on("--package",
                    "Cluster by Packwerk packages discovered in cwd") do
              @state[:package] ||= "."
            end
            opts.on("--package-root PATH",
                    "Cluster by Packwerk packages discovered under PATH") do |root|
              @state[:package] = root
            end
            add_filter_options(opts, @state)
            opts.on("-h", "--help") do
              @stdout.puts opts
              exit 0
            end
          end
          parser.parse!(argv)
        end

        def rendered(edges, groups)
          case @format
          when :dot then Dot.render(edges, collapse: @state[:collapse], groups: groups)
          when :mermaid then Mermaid.render(edges, collapse: @state[:collapse], groups: groups)
          end
        end
      end

      # `class-diagram` renders a Mermaid +classDiagram+ document
      # from the +edges.jsonl+ (the dependency graph) and the
      # +nodes.jsonl+ (class declarations + methods + attributes).
      # Phase 5 of the project — turns the dependency graph
      # material into a UML-style class diagram.
      class ClassDiagramCmd
        include EdgeFilters

        DEFAULT_NODES_PATH = CLI::DEFAULT_NODES_PATH

        def initialize(stdout:, stderr:, stdin:)
          @stdout = stdout
          @stderr = stderr
          @stdin = stdin
          @options = {
            kinds: nil, confidences: nil,
            from: nil, depth: nil, direction: :both, edge_scope: :cluster,
            nodes_path: nil,
            include_methods: true,
            include_attributes: true,
            visibilities: %w[public protected private]
          }
        end

        def run(argv)
          argv = argv.dup
          parse_options!(argv)
          edges_path = argv.shift
          io = edges_path ? File.open(edges_path, "r") : @stdin
          begin
            edges = EdgeIO.read(io)
          ensure
            io.close if edges_path && !io.closed?
          end

          edges = apply_filters(
            edges,
            kinds: @options[:kinds],
            confidences: @options[:confidences],
            from: @options[:from],
            depth: @options[:depth],
            direction: @options[:direction],
            edge_scope: @options[:edge_scope]
          )

          nodes_path = @options[:nodes_path] || default_nodes_for(edges_path)
          nodes = read_nodes(nodes_path)

          out = Uml::ClassDiagram.render(
            edges, nodes,
            include_methods: @options[:include_methods],
            include_attributes: @options[:include_attributes],
            visibilities: @options[:visibilities]
          )
          @stdout.print(out)
          0
        rescue OptionParser::ParseError => e
          @stderr.puts "rigor-module-graph class-diagram: #{e.message}"
          2
        rescue Errno::ENOENT => e
          @stderr.puts "rigor-module-graph class-diagram: #{e.message}"
          1
        end

        def parse_options!(argv)
          parser = OptionParser.new do |opts|
            opts.banner = "Usage: rigor-module-graph class-diagram [options] [EDGES_FILE]"
            opts.on("--nodes PATH",
                    "Path to the nodes JSONL (default: sibling of EDGES_FILE)") do |path|
              @options[:nodes_path] = path
            end
            opts.on("--no-methods",
                    "Don't render methods inside class bodies") do
              @options[:include_methods] = false
            end
            opts.on("--no-attributes",
                    "Don't render attributes inside class bodies") do
              @options[:include_attributes] = false
            end
            opts.on("--public-only",
                    "Only show public members") do
              @options[:visibilities] = %w[public]
            end
            opts.on("--no-private",
                    "Hide private members") do
              @options[:visibilities] = %w[public protected]
            end
            add_filter_options(opts, @options)
            opts.on("-h", "--help") do
              @stdout.puts opts
              exit 0
            end
          end
          parser.parse!(argv)
        end

        def default_nodes_for(edges_path)
          return DEFAULT_NODES_PATH unless edges_path

          File.join(File.dirname(edges_path), "nodes.jsonl")
        end

        def read_nodes(path)
          return [] unless path && File.exist?(path)

          File.open(path, "r") { |io| NodeIO.read(io) }
        end
      end

      # `stats` reports the fan-out / fan-in / internal / nodes
      # numbers per namespace. Same filter flags as the renderers
      # so a focused subgraph can be summarised without
      # regenerating the JSONL.
      class StatsCmd
        include EdgeFilters

        FORMATS = %w[text json].freeze
        HEADERS = %w[namespace nodes fan-out fan-in internal total].freeze

        def initialize(stdout:, stderr:, stdin:)
          @stdout = stdout
          @stderr = stderr
          @stdin = stdin
          @state = {
            kinds: nil, confidences: nil,
            from: nil, depth: nil, direction: :both, edge_scope: :cluster,
            grouping_depth: 1, format: "text", limit: nil
          }
        end

        def run(argv)
          argv = argv.dup
          parse_options!(argv)
          path, = argv
          io = path ? File.open(path, "r") : @stdin
          begin
            edges = EdgeIO.read(io)
          ensure
            io.close if path && !io.closed?
          end
          edges = apply_filters(
            edges,
            kinds: @state[:kinds],
            confidences: @state[:confidences],
            from: @state[:from],
            depth: @state[:depth],
            direction: @state[:direction],
            edge_scope: @state[:edge_scope]
          )
          metrics = Stats.compute(edges, depth: @state[:grouping_depth])
          metrics = metrics.first(@state[:limit]) if @state[:limit]
          render(metrics)
          0
        rescue OptionParser::ParseError => e
          @stderr.puts "rigor-module-graph stats: #{e.message}"
          2
        end

        def parse_options!(argv)
          parser = OptionParser.new do |opts|
            opts.banner = "Usage: rigor-module-graph stats [options] [FILE]"
            opts.on("--grouping-depth N", Integer,
                    "How many leading namespace segments to group by (default: 1)") do |n|
              @state[:grouping_depth] = n
            end
            opts.on("--limit N", Integer,
                    "Show only the top N namespaces by fan-out") do |n|
              @state[:limit] = n
            end
            opts.on("--format FORMAT", FORMATS,
                    "Output format (#{FORMATS.join("/")}; default: text)") do |fmt|
              @state[:format] = fmt
            end
            add_filter_options(opts, @state)
            opts.on("-h", "--help") do
              @stdout.puts opts
              exit 0
            end
          end
          parser.parse!(argv)
        end

        def render(metrics)
          case @state[:format]
          when "json"
            @stdout.puts(JSON.pretty_generate(metrics.map(&:to_h)))
          when "text"
            @stdout.print(format_table(metrics))
          end
        end

        # A space-padded text table sized to the widest cell per
        # column. Numeric columns are right-aligned so a quick
        # eye-scan finds the hotspots.
        def format_table(metrics)
          if metrics.empty?
            return "(no edges)\n"
          end

          rows = metrics.map do |m|
            [m.namespace, m.nodes.to_s, m.fan_out.to_s, m.fan_in.to_s,
             m.internal.to_s, m.total.to_s]
          end
          widths = HEADERS.zip(*rows).map { |col| col.map(&:length).max }

          out = +""
          out << format_row(HEADERS, widths) << "\n"
          out << ("-" * widths.sum { |w| w + 2 }) << "\n"
          rows.each { |row| out << format_row(row, widths) << "\n" }
          out
        end

        def format_row(row, widths)
          row.each_with_index.map do |cell, idx|
            idx.zero? ? cell.ljust(widths[idx]) : cell.rjust(widths[idx])
          end.join("  ")
        end
      end

      class Cycles
        include EdgeFilters

        def initialize(stdout:, stderr:, stdin:)
          @stdout = stdout
          @stderr = stderr
          @stdin = stdin
          @state = {
            kinds: nil, confidences: nil,
            from: nil, depth: nil, direction: :both
          }
        end

        def run(argv)
          argv = argv.dup
          parse_options!(argv)
          path, = argv
          io = path ? File.open(path, "r") : @stdin
          begin
            edges = EdgeIO.read(io)
          ensure
            io.close if path && !io.closed?
          end
          edges = apply_filters(
            edges,
            kinds: @state[:kinds],
            confidences: @state[:confidences],
            from: @state[:from],
            depth: @state[:depth],
            direction: @state[:direction],
            edge_scope: @state[:edge_scope]
          )
          cycles = CycleDetector.detect(edges)
          if cycles.empty?
            @stderr.puts "rigor-module-graph cycles: no cycles found"
            0
          else
            cycles.each { |c| @stdout.puts c.to_s }
            1
          end
        rescue OptionParser::ParseError => e
          @stderr.puts "rigor-module-graph cycles: #{e.message}"
          2
        end

        def parse_options!(argv)
          parser = OptionParser.new do |opts|
            opts.banner = "Usage: rigor-module-graph cycles [options] [FILE]"
            # `--only` kept as an alias for `--kind` for backward
            # compat with the Phase 1 flag.
            opts.on("--only KINDS", Array,
                    "Alias for --kind") do |kinds|
              @state[:kinds] = kinds
            end
            add_filter_options(opts, @state)
            opts.on("-h", "--help") do
              @stdout.puts opts
              exit 0
            end
          end
          parser.parse!(argv)
        end
      end
    end
  end
end
