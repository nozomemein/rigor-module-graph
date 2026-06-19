# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "optparse"
require "set"
require "shellwords"

require_relative "edge"
require_relative "dot"
require_relative "mermaid"
require_relative "cycle_detector"
require_relative "html_view"

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
      SOURCE_FAMILY = "plugin.module-graph"
      EDGE_RULE = "edge"

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
        when "-h", "--help", "help"
          stdout.puts USAGE
          0
        when "version", "-v", "--version"
          stdout.puts Rigor::ModuleGraph::VERSION
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
          view    [PATHS...]   Analyse, write HTML, open in a browser
          collect [PATHS...]   Run `rigor check` and write edges JSONL
          dot     [FILE]       Render edges JSONL as Graphviz DOT
          mermaid [FILE]       Render edges JSONL as Mermaid
          cycles  [FILE]       Detect cycles in edges JSONL

        Run `rigor-module-graph <command> --help` for command-specific options.
      USAGE

      # Shared filter options reused by dot / mermaid / cycles.
      module EdgeFilters
        VALID_KINDS = Rigor::ModuleGraph::EDGE_KINDS
        VALID_CONFIDENCES = Rigor::ModuleGraph::EDGE_CONFIDENCES

        def apply_filters(edges, kinds:, confidences:)
          edges = edges.select { |e| kinds.include?(e.kind) } if kinds
          edges = edges.select { |e| confidences.include?(e.confidence) } if confidences
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
      # and the diagnostic → Edge transformation. Reused by both
      # `Collect` (write JSONL) and `View` (render HTML).
      class RigorRunner
        def initialize(rigor_cmd: ENV.fetch("RIGOR_CMD", "rigor"), cache: false)
          @rigor_cmd = rigor_cmd
          @cache = cache
        end

        def edges_for(paths)
          diagnostics = run_rigor(paths)
          diagnostics_to_edges(diagnostics)
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
            cache: false,
            rigor_cmd: ENV.fetch("RIGOR_CMD", "rigor")
          }
        end

        def run(argv)
          parser = build_parser
          paths = parser.parse(argv)

          ensure_output_dir
          runner = RigorRunner.new(rigor_cmd: @options[:rigor_cmd], cache: @options[:cache])
          edges = runner.edges_for(paths)
          write_edges(edges)
          @stderr.puts "rigor-module-graph: wrote #{edges.size} edge(s) to #{@options[:output]}"
          0
        rescue OptionParser::ParseError => e
          @stderr.puts "rigor-module-graph collect: #{e.message}"
          2
        rescue CollectError => e
          @stderr.puts "rigor-module-graph collect: #{e.message}"
          1
        end

        def build_parser
          OptionParser.new do |opts|
            opts.banner = "Usage: rigor-module-graph collect [options] [PATHS...]"
            opts.on("-o", "--output PATH",
                    "Write edges to PATH (default: #{DEFAULT_EDGES_PATH})") do |path|
              @options[:output] = path
            end
            opts.on("--[no-]cache",
                    "Pass `--cache` / `--no-cache` to rigor (default: --no-cache)") do |cache|
              @options[:cache] = cache
            end
            opts.on("--rigor-cmd CMD",
                    "Override the rigor binary (default: rigor or $RIGOR_CMD)") do |cmd|
              @options[:rigor_cmd] = cmd
            end
            opts.on("-h", "--help") do
              @stdout.puts opts
              exit 0
            end
          end
        end

        def ensure_output_dir
          dir = File.dirname(@options[:output])
          FileUtils.mkdir_p(dir) unless dir.empty?
        end

        def write_edges(edges)
          File.open(@options[:output], "w") do |io|
            EdgeIO.write(edges, io)
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
        AUTO_COLLAPSE_THRESHOLD = 2

        def initialize(stdout:, stderr:)
          @stdout = stdout
          @stderr = stderr
          @options = {
            output: DEFAULT_OUTPUT,
            cache: false,
            rigor_cmd: ENV.fetch("RIGOR_CMD", "rigor"),
            open: true,
            collapse: nil,
            kinds: nil,
            confidences: nil
          }
        end

        def run(argv)
          parser = build_parser
          paths = parser.parse(argv)

          ensure_output_dir
          runner = RigorRunner.new(rigor_cmd: @options[:rigor_cmd], cache: @options[:cache])
          edges = runner.edges_for(paths)
          edges = apply_filters(edges, kinds: @options[:kinds], confidences: @options[:confidences])
          collapse = effective_collapse(edges)

          mermaid = Mermaid.render(edges, collapse: collapse)
          html = HtmlView.render(
            title: "rigor-module-graph: #{File.basename(Dir.pwd)}",
            subtitle: render_subtitle(edges, collapse),
            mermaid_source: mermaid
          )
          File.write(@options[:output], html)
          @stderr.puts "rigor-module-graph: wrote #{edges.size} edge(s) to #{@options[:output]}"
          open_in_browser(@options[:output]) if @options[:open]
          0
        rescue OptionParser::ParseError => e
          @stderr.puts "rigor-module-graph view: #{e.message}"
          2
        rescue CollectError => e
          @stderr.puts "rigor-module-graph view: #{e.message}"
          1
        end

        def build_parser
          OptionParser.new do |opts|
            opts.banner = "Usage: rigor-module-graph view [options] [PATHS...]"
            opts.on("-o", "--output PATH",
                    "Write HTML to PATH (default: #{DEFAULT_OUTPUT})") do |path|
              @options[:output] = path
            end
            opts.on("--[no-]open",
                    "Open the HTML in a browser (default: true)") do |flag|
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
            opts.on("--[no-]cache",
                    "Pass --cache / --no-cache to rigor (default: --no-cache)") do |cache|
              @options[:cache] = cache
            end
            opts.on("--rigor-cmd CMD",
                    "Override the rigor binary (default: rigor or $RIGOR_CMD)") do |cmd|
              @options[:rigor_cmd] = cmd
            end
            add_filter_options(opts, @options)
            opts.on("-h", "--help") do
              @stdout.puts opts
              exit 0
            end
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

              counts[head] << name
            end
          end
          counts.select { |_, members| members.size >= AUTO_COLLAPSE_THRESHOLD }.keys.sort
        end

        def render_subtitle(edges, collapse)
          parts = ["#{edges.size} edge(s) from #{Dir.pwd}"]
          parts << "collapsed: #{collapse.join(", ")}" unless collapse.empty?
          parts.join(" · ")
        end

        def ensure_output_dir
          dir = File.dirname(@options[:output])
          FileUtils.mkdir_p(dir) unless dir.empty?
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
          @state = { collapse: [], kinds: nil, confidences: nil }
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
          edges = apply_filters(edges, kinds: @state[:kinds], confidences: @state[:confidences])
          @stdout.print(rendered(edges))
          0
        rescue Errno::ENOENT => e
          @stderr.puts "rigor-module-graph #{@format}: #{e.message}"
          1
        rescue OptionParser::ParseError => e
          @stderr.puts "rigor-module-graph #{@format}: #{e.message}"
          2
        end

        def parse_options!(argv)
          parser = OptionParser.new do |opts|
            opts.banner = "Usage: rigor-module-graph #{@format} [options] [FILE]"
            opts.on("--collapse PREFIXES", Array,
                    "Comma-separated namespace prefixes to fold into clusters") do |prefixes|
              @state[:collapse].concat(prefixes)
            end
            add_filter_options(opts, @state)
            opts.on("-h", "--help") do
              @stdout.puts opts
              exit 0
            end
          end
          parser.parse!(argv)
        end

        def rendered(edges)
          case @format
          when :dot then Dot.render(edges, collapse: @state[:collapse])
          when :mermaid then Mermaid.render(edges, collapse: @state[:collapse])
          end
        end
      end

      class Cycles
        include EdgeFilters

        def initialize(stdout:, stderr:, stdin:)
          @stdout = stdout
          @stderr = stderr
          @stdin = stdin
          @state = { kinds: nil, confidences: nil }
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
          edges = apply_filters(edges, kinds: @state[:kinds], confidences: @state[:confidences])
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
