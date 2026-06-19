# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "optparse"
require "shellwords"

require_relative "edge"
require_relative "dot"
require_relative "mermaid"
require_relative "cycle_detector"

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
    # reads stdin if no path is given. `collect` shells out to the
    # host project's `rigor` binary; the user is expected to have
    # `rigor-module-graph` listed in `.rigor.yml` `plugins:` for the
    # plugin to be loaded.
    module CLI
      DEFAULT_EDGES_PATH = ".rigor/module_graph/edges.jsonl"
      SOURCE_FAMILY = "plugin.module-graph"
      EDGE_RULE = "edge"

      module_function

      def run(argv, stdout: $stdout, stderr: $stderr, stdin: $stdin)
        argv = argv.dup
        command = argv.shift
        case command
        when "collect"
          Collect.new(stdout: stdout, stderr: stderr).run(argv)
        when "dot"
          Render.new(:dot, stdout: stdout, stderr: stderr, stdin: stdin).run(argv)
        when "mermaid"
          Render.new(:mermaid, stdout: stdout, stderr: stderr, stdin: stdin).run(argv)
        when "cycles"
          Cycles.new(stdout: stdout, stderr: stderr, stdin: stdin).run(argv)
        when nil, "-h", "--help"
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
        Usage: rigor-module-graph <command> [options] [paths]

        Commands:
          collect [PATHS...]   Run `rigor check` and write edges JSONL
          dot     [FILE]       Render edges JSONL as Graphviz DOT
          mermaid [FILE]       Render edges JSONL as Mermaid
          cycles  [FILE]       Detect cycles in edges JSONL

        Run `rigor-module-graph <command> --help` for command-specific options.
      USAGE

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
          diagnostics = run_rigor(paths)
          edges = diagnostics_to_edges(diagnostics)
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

        def run_rigor(paths)
          cmd = [@options[:rigor_cmd], "check", "--format", "json"]
          cmd << (@options[:cache] ? "--cache" : "--no-cache")
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

        def write_edges(edges)
          File.open(@options[:output], "w") do |io|
            EdgeIO.write(edges, io)
          end
        end

        class CollectError < StandardError; end
      end

      # Shared base for `dot` / `mermaid` — both load an edges JSONL
      # and print a rendered string.
      class Render
        def initialize(format, stdout:, stderr:, stdin:)
          @format = format
          @stdout = stdout
          @stderr = stderr
          @stdin = stdin
        end

        def run(argv)
          path, = argv
          io = path ? File.open(path, "r") : @stdin
          begin
            edges = EdgeIO.read(io)
          ensure
            io.close if path && !io.closed?
          end
          @stdout.print(rendered(edges))
          0
        rescue Errno::ENOENT => e
          @stderr.puts "rigor-module-graph #{@format}: #{e.message}"
          1
        end

        def rendered(edges)
          case @format
          when :dot then Dot.render(edges)
          when :mermaid then Mermaid.render(edges)
          end
        end
      end

      class Cycles
        def initialize(stdout:, stderr:, stdin:)
          @stdout = stdout
          @stderr = stderr
          @stdin = stdin
          @kinds = nil
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
          cycles = CycleDetector.detect(edges, kinds: @kinds)
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
            opts.on("--only KINDS", Array,
                    "Comma-separated edge kinds to include (default: all)") do |kinds|
              @kinds = kinds
            end
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
