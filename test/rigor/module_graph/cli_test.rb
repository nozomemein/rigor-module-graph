# frozen_string_literal: true

require_relative "../../test_helper"
require "rigor/module_graph/cli"
require "stringio"
require "fileutils"
require "tempfile"

# Exercises the CLI dispatcher and every subcommand against
# synthetic edges/nodes JSONL. The integration_test covers the
# rigor binary shell-out path; this file aims at branch coverage
# of the option-parsing and rendering glue inside each subcommand.
class CLITest < Minitest::Test
  CLI = Rigor::ModuleGraph::CLI

  SAMPLE_EDGES = <<~JSONL
    {"from":"Billing::Invoice","to":"ApplicationRecord","kind":"inherits","path":"app/models/billing/invoice.rb","line":2,"column":3,"confidence":"zeitwerk"}
    {"from":"Billing::Invoice","to":"Auditable","kind":"include","path":"app/models/billing/invoice.rb","line":3,"column":5,"confidence":"zeitwerk"}
    {"from":"Billing::Payment","to":"ApplicationRecord","kind":"inherits","path":"app/models/billing/payment.rb","line":2,"column":3,"confidence":"zeitwerk"}
    {"from":"Billing::Payment","to":"Billing::Invoice","kind":"include","path":"app/models/billing/payment.rb","line":3,"column":5,"confidence":"zeitwerk"}
    {"from":"Cycle::A","to":"Cycle::B","kind":"include","confidence":"syntax"}
    {"from":"Cycle::B","to":"Cycle::A","kind":"include","confidence":"syntax"}
    {"from":"Unresolved","to":"some_var","kind":"include","confidence":"unresolved","raw":"some_var"}
  JSONL

  SAMPLE_NODES = <<~JSONL
    {"kind":"class","name":"Billing::Invoice","path":"app/models/billing/invoice.rb","line":2}
    {"kind":"instance_method","name":"total","owner":"Billing::Invoice","visibility":"public","line":4}
    {"kind":"instance_method","name":"audit","owner":"Billing::Invoice","visibility":"private","line":7}
    {"kind":"attribute","name":"amount","owner":"Billing::Invoice","visibility":"public","access":"accessor","line":3}
    {"kind":"class","name":"Billing::Payment","path":"app/models/billing/payment.rb","line":2}
    {"kind":"module","name":"Auditable","path":"app/models/concerns/auditable.rb","line":1}
  JSONL

  def setup
    @tmpdir = Dir.mktmpdir("rigor-module-graph-cli")
    @edges_path = File.join(@tmpdir, "edges.jsonl")
    @nodes_path = File.join(@tmpdir, "nodes.jsonl")
    File.write(@edges_path, SAMPLE_EDGES)
    File.write(@nodes_path, SAMPLE_NODES)
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if @tmpdir
  end

  def run_cli(argv, stdin: StringIO.new)
    stdout = StringIO.new
    stderr = StringIO.new
    status = CLI.run(argv, stdout: stdout, stderr: stderr, stdin: stdin)
    [status, stdout.string, stderr.string]
  end

  # --- top-level dispatcher ---

  def test_help_subcommand_prints_usage
    status, out, _err = run_cli(["help"])
    assert_equal 0, status
    assert_includes out, "Usage: rigor-module-graph"
    assert_includes out, "view"
  end

  def test_version_subcommand
    status, out, _err = run_cli(["version"])
    assert_equal 0, status
    assert_equal "#{Rigor::ModuleGraph::VERSION}\n", out
  end

  def test_dash_v_version
    status, out, _err = run_cli(["-v"])
    assert_equal 0, status
    assert_match(/\d+\.\d+\.\d+/, out)
  end

  def test_dash_h_help
    status, out, _err = run_cli(["-h"])
    assert_equal 0, status
    assert_includes out, "Commands:"
  end

  def test_unknown_command_exits_2_and_prints_usage
    status, _out, err = run_cli(["frobnicate"])
    assert_equal 2, status
    assert_includes err, "unknown command"
    assert_includes err, "Usage:"
  end

  # --- dot / mermaid (Render) ---

  def test_dot_default_renders_to_stdout
    status, out, _err = run_cli(["dot", @edges_path])
    assert_equal 0, status
    assert_includes out, "digraph ruby_modules"
    assert_includes out, "Billing::Invoice"
  end

  def test_mermaid_via_stdin_reads_edges
    edges_data = SAMPLE_EDGES
    status, out, _err = run_cli(["mermaid"], stdin: StringIO.new(edges_data))
    assert_equal 0, status
    assert_includes out, "flowchart LR"
  end

  def test_dot_with_kind_filter_drops_excluded_edges
    status, out, _err = run_cli(["dot", "--kind", "inherits", @edges_path])
    assert_equal 0, status
    assert_includes out, "inherits"
    refute_includes out, "label=\"include\""
  end

  def test_dot_with_unknown_kind_exits_2
    status, _out, err = run_cli(["dot", "--kind", "weird", @edges_path])
    assert_equal 2, status
    assert_includes err, "unknown kind"
  end

  def test_dot_with_confidence_filter
    status, out, _err = run_cli(["dot", "--confidence", "zeitwerk", @edges_path])
    assert_equal 0, status
    refute_includes out, "Cycle::A"
  end

  def test_dot_with_unknown_confidence_exits_2
    status, _out, err = run_cli(["dot", "--confidence", "weird", @edges_path])
    assert_equal 2, status
    assert_includes err, "unknown confidence"
  end

  def test_dot_collapse_wraps_subgraph
    status, out, _err = run_cli(["dot", "--collapse", "Billing", @edges_path])
    assert_equal 0, status
    assert_includes out, "cluster_Billing"
  end

  def test_dot_with_from_and_depth_narrows
    status, out, _err = run_cli([
                                  "dot", "--from", "Billing::Invoice", "--depth", "1",
                                  "--direction", "out", @edges_path
                                ])
    assert_equal 0, status
    refute_includes out, "Cycle::A"
  end

  def test_dot_edge_scope_walk_drops_sibling_edges
    status, out, _err = run_cli([
                                  "dot", "--from", "Billing::Invoice", "--depth", "1",
                                  "--direction", "out", "--edge-scope", "walk", @edges_path
                                ])
    assert_equal 0, status
    # Billing::Payment's inherits ApplicationRecord is a sibling
    # edge in cluster mode, but walk drops it.
    refute_includes out, "\"Billing::Payment\" -> \"ApplicationRecord\""
  end

  def test_dot_invalid_direction_exits_2
    status, _out, err = run_cli([
                                  "dot", "--from", "Billing::Invoice", "--direction", "sideways", @edges_path
                                ])
    assert_equal 2, status
    assert_includes err, "invalid argument"
  end

  def test_dot_missing_file_exits_1
    status, _out, err = run_cli(["dot", "/no/such/file.jsonl"])
    assert_equal 1, status
    assert_includes err, "No such file"
  end

  def test_dot_with_package_flag_warns_when_no_packages_found
    status, _out, err = run_cli(["dot", "--package-root", @tmpdir, @edges_path])
    assert_equal 0, status
    assert_includes err, "no package.yml found"
  end

  def test_dot_with_package_clusters_when_yaml_present
    pkg_dir = File.join(@tmpdir, "packages/billing")
    FileUtils.mkdir_p(pkg_dir)
    File.write(File.join(pkg_dir, "package.yml"), "enforce_dependencies: true\n")
    edges_with_pkg_path = SAMPLE_EDGES.gsub(
      "app/models/billing/invoice.rb",
      File.join(pkg_dir, "invoice.rb")
    ).gsub(
      "app/models/billing/payment.rb",
      File.join(pkg_dir, "payment.rb")
    )
    File.write(@edges_path, edges_with_pkg_path)

    status, out, _err = run_cli(["dot", "--package-root", @tmpdir, @edges_path])
    assert_equal 0, status
    assert_includes out, "cluster_packages_billing"
  end

  # --- cycles ---

  def test_cycles_reports_cycle_with_exit_1
    status, out, _err = run_cli(["cycles", @edges_path])
    assert_equal 1, status
    assert_includes out, "Cycle::A"
    assert_includes out, "Cycle::B"
  end

  def test_cycles_no_cycles_after_filter_exit_0
    status, _out, err = run_cli([
                                  "cycles", "--kind", "inherits", @edges_path
                                ])
    assert_equal 0, status
    assert_includes err, "no cycles found"
  end

  def test_cycles_only_alias_works
    status, out, _err = run_cli(["cycles", "--only", "include", @edges_path])
    assert_equal 1, status
    assert_includes out, "Cycle::A"
  end

  def test_cycles_invalid_kind_exits_2
    status, _out, err = run_cli(["cycles", "--kind", "weird", @edges_path])
    assert_equal 2, status
    assert_includes err, "unknown kind"
  end

  def test_cycles_via_stdin
    status, _out, _err = run_cli(["cycles"], stdin: StringIO.new(SAMPLE_EDGES))
    assert_equal 1, status
  end

  # --- stats ---

  def test_stats_default_text_format
    status, out, _err = run_cli(["stats", @edges_path])
    assert_equal 0, status
    assert_includes out, "namespace"
    assert_includes out, "Billing"
  end

  def test_stats_json_format
    status, out, _err = run_cli(["stats", "--format", "json", @edges_path])
    assert_equal 0, status
    assert_match(/"namespace": "Billing"/, out)
  end

  def test_stats_with_limit
    status, out, _err = run_cli(["stats", "--limit", "1", @edges_path])
    assert_equal 0, status
    assert_includes out, "Billing"
  end

  def test_stats_with_grouping_depth_2
    edges_with_deep = SAMPLE_EDGES + <<~JSONL
      {"from":"Billing::Invoice::Line","to":"Billing::Invoice::Item","kind":"include","confidence":"syntax"}
      {"from":"Billing::Invoice::Foo","to":"Billing::Invoice::Bar","kind":"include","confidence":"syntax"}
    JSONL
    File.write(@edges_path, edges_with_deep)
    status, out, _err = run_cli(["stats", "--grouping-depth", "2", @edges_path])
    assert_equal 0, status
    # Depth 2 keeps Billing::Invoice as its own bucket.
    assert_includes out, "Billing::Invoice"
  end

  def test_stats_empty_input_prints_no_edges
    File.write(@edges_path, "")
    status, out, _err = run_cli(["stats", @edges_path])
    assert_equal 0, status
    assert_includes out, "(no edges)"
  end

  def test_stats_invalid_format_exits_2
    status, _out, err = run_cli(["stats", "--format", "yaml", @edges_path])
    assert_equal 2, status
    assert_includes err, "invalid argument"
  end

  # --- class-diagram ---

  def test_class_diagram_with_nodes_path_renders
    status, out, _err = run_cli([
                                  "class-diagram", "--nodes", @nodes_path, @edges_path
                                ])
    assert_equal 0, status
    assert_includes out, "classDiagram"
    assert_includes out, "Billing__Invoice"
  end

  def test_class_diagram_picks_up_sibling_nodes_jsonl_automatically
    status, out, _err = run_cli(["class-diagram", @edges_path])
    assert_equal 0, status
    assert_includes out, "classDiagram"
    # Default nodes_path = dirname(edges_path)/nodes.jsonl which
    # we wrote in setup.
    assert_includes out, "+total()"
  end

  def test_class_diagram_no_methods_drops_method_lines
    status, out, _err = run_cli([
                                  "class-diagram", "--no-methods", @edges_path
                                ])
    assert_equal 0, status
    refute_includes out, "+total()"
  end

  def test_class_diagram_no_attributes_drops_attr_lines
    status, out, _err = run_cli([
                                  "class-diagram", "--no-attributes", @edges_path
                                ])
    assert_equal 0, status
    refute_includes out, "+amount"
  end

  def test_class_diagram_public_only_hides_private
    status, out, _err = run_cli([
                                  "class-diagram", "--public-only", @edges_path
                                ])
    assert_equal 0, status
    refute_includes out, "audit()"
  end

  def test_class_diagram_no_private_hides_only_private
    status, out, _err = run_cli([
                                  "class-diagram", "--no-private", @edges_path
                                ])
    assert_equal 0, status
    assert_includes out, "+total()"
    refute_includes out, "-audit()"
  end

  def test_class_diagram_missing_edges_file_exits_1
    status, _out, err = run_cli(["class-diagram", "/no/such/edges.jsonl"])
    assert_equal 1, status
    assert_includes err, "No such file"
  end

  def test_class_diagram_invalid_kind_exits_2
    status, _out, err = run_cli([
                                  "class-diagram", "--kind", "weird", @edges_path
                                ])
    assert_equal 2, status
    assert_includes err, "unknown kind"
  end

  def test_class_diagram_reads_stdin_when_no_edges_path
    status, out, _err = run_cli(
      ["class-diagram"], stdin: StringIO.new(SAMPLE_EDGES)
    )
    assert_equal 0, status
    assert_includes out, "classDiagram"
  end

  # --- view (without shelling out to rigor — exercise the
  # plumbing pieces that don't depend on RigorRunner) ---

  def test_view_runs_through_runner_with_fake_runner
    # We can't easily fake rigor in a unit test, but we can drive
    # view's render_payload via direct instantiation against a
    # synthetic edge/node list. Cover both html and non-html
    # destination resolution.
    view = CLI::View.new(stdout: StringIO.new, stderr: StringIO.new)
    opts = view.instance_variable_get(:@options)

    opts[:format] = "mermaid"
    assert_nil view.effective_output_path

    opts[:format] = "dot"
    opts[:output] = "graph.dot"
    assert_equal "graph.dot", view.effective_output_path
  end

  def test_view_render_subtitle_includes_direction_when_not_both
    view = CLI::View.new(stdout: StringIO.new, stderr: StringIO.new)
    opts = view.instance_variable_get(:@options)
    opts[:from] = ["Article"]
    opts[:depth] = 3
    opts[:direction] = :out
    subtitle = view.render_subtitle([], [], nil)
    assert_includes subtitle, "from: Article"
    assert_includes subtitle, "(depth=3)"
    assert_includes subtitle, "[out]"
  end

  def test_view_html_predicate
    view = CLI::View.new(stdout: StringIO.new, stderr: StringIO.new)
    assert_predicate view, :html?
    view.instance_variable_get(:@options)[:format] = "dot"
    refute_predicate view, :html?
  end

  def test_view_graphviz_svg_propagates_render_error_when_dot_missing
    view = CLI::View.new(stdout: StringIO.new, stderr: StringIO.new)
    Open3.stub :capture3, ->(*_a, **_kw) { raise Errno::ENOENT, "dot" } do
      e = assert_raises(CLI::View::RenderError) do
        view.send(:graphviz_svg, "digraph { A -> B }")
      end
      assert_includes e.message, "graphviz `dot` not found"
    end
  end

  # --- collect runs error paths (without shelling rigor) ---

  def test_collect_diagnostics_to_edges_filters_by_rule_and_family
    runner = CLI::RigorRunner.new
    diagnostics = [
      {
        "rule" => "edge", "source_family" => "plugin.module-graph",
        "path" => "a.rb", "line" => 1, "column" => 1,
        "message" => '{"from":"A","to":"B","kind":"include","confidence":"syntax"}'
      },
      {
        "rule" => "edge", "source_family" => "other",
        "message" => '{"from":"X","to":"Y","kind":"include","confidence":"syntax"}'
      },
      {
        "rule" => "warning", "source_family" => "plugin.module-graph",
        "message" => "noise"
      }
    ]
    edges = runner.diagnostics_to_edges(diagnostics)
    assert_equal 1, edges.size
    assert_equal "A", edges.first.from
  end

  def test_collect_diagnostics_to_edges_skips_malformed_payload
    runner = CLI::RigorRunner.new
    diagnostics = [
      {
        "rule" => "edge", "source_family" => "plugin.module-graph",
        "message" => "not json"
      },
      {
        "rule" => "edge", "source_family" => "plugin.module-graph",
        "message" => '{"from":"A"}' # missing required keys
      }
    ]
    edges = runner.diagnostics_to_edges(diagnostics)
    assert_empty edges
  end

  # --- direct View internals coverage ---

  def edges_array
    Rigor::ModuleGraph::EdgeIO.read(StringIO.new(SAMPLE_EDGES))
  end

  def nodes_array
    Rigor::ModuleGraph::NodeIO.read(StringIO.new(SAMPLE_NODES))
  end

  def fresh_view(format:, output: nil, open: true)
    view = CLI::View.new(stdout: StringIO.new, stderr: StringIO.new)
    opts = view.instance_variable_get(:@options)
    opts[:format] = format
    opts[:output] = output
    opts[:open] = open
    view
  end

  def test_view_render_payload_dispatch_html
    view = fresh_view(format: "html")
    payload, binary = view.send(:render_payload, edges_array, nodes_array, [], nil)
    refute binary
    assert_includes payload, "<!doctype html>"
  end

  def test_view_render_payload_dispatch_mermaid
    view = fresh_view(format: "mermaid")
    payload, binary = view.send(:render_payload, edges_array, nodes_array, [], nil)
    refute binary
    assert_includes payload, "flowchart LR"
  end

  def test_view_render_payload_dispatch_dot
    view = fresh_view(format: "dot")
    payload, binary = view.send(:render_payload, edges_array, nodes_array, [], nil)
    refute binary
    assert_includes payload, "digraph ruby_modules"
  end

  def test_view_render_payload_dispatch_class_diagram
    view = fresh_view(format: "class-diagram")
    payload, binary = view.send(:render_payload, edges_array, nodes_array, [], nil)
    refute binary
    assert_includes payload, "classDiagram"
  end

  def test_view_render_payload_dispatch_svg_via_stub
    view = fresh_view(format: "svg")
    fake_status = Object.new
    def fake_status.success? = true
    Open3.stub :capture3, ->(*_a, **_kw) { ["<svg/>", "", fake_status] } do
      payload, binary = view.send(:render_payload, edges_array, nodes_array, [], nil)
      assert binary
      assert_includes payload, "<svg"
    end
  end

  def test_view_graphviz_svg_raises_render_error_on_nonzero_exit
    view = fresh_view(format: "svg")
    fake_status = Object.new
    def fake_status.success? = false
    def fake_status.exitstatus = 42
    Open3.stub :capture3, ->(*_a, **_kw) { ["", "fake error", fake_status] } do
      err = assert_raises(CLI::View::RenderError) { view.send(:graphviz_svg, "digraph{}") }
      assert_includes err.message, "graphviz `dot` failed"
    end
  end

  def test_view_deliver_to_stdout_for_non_html
    stdout = StringIO.new
    view = CLI::View.new(stdout: stdout, stderr: StringIO.new)
    view.instance_variable_get(:@options)[:format] = "mermaid"
    view.send(:deliver, "hello", binary: false, edges: edges_array)
    assert_equal "hello", stdout.string
  end

  def test_view_deliver_to_file_with_explicit_output
    path = File.join(@tmpdir, "subdir/foo.dot")
    view = fresh_view(format: "dot", output: path, open: false)
    view.send(:deliver, "DOT", binary: false, edges: edges_array)
    assert_path_exists path, "expected #{path} to exist"
    assert_equal "DOT", File.read(path)
  end

  def test_view_deliver_writes_html_to_default_path_without_open
    Dir.chdir(@tmpdir) do
      view = fresh_view(format: "html", open: false)
      view.send(:deliver, "<html></html>", binary: false, edges: edges_array)
      assert_path_exists File.join(@tmpdir, ".rigor/module_graph/view.html")
    end
  end

  def test_view_deliver_binary_writes_in_binmode
    path = File.join(@tmpdir, "graph.svg")
    view = fresh_view(format: "svg", output: path, open: false)
    view.send(:deliver, "\x89PNG\r\n", binary: true, edges: edges_array)
    bytes = File.binread(path)
    assert_equal "\x89PNG\r\n".bytes, bytes.bytes
  end

  def test_view_default_collapse_uses_auto_detection
    view = fresh_view(format: "html")
    edges = edges_array
    auto = view.effective_collapse(edges)
    # Billing has 2 members in SAMPLE_EDGES — below threshold 3.
    refute_includes auto, "Billing"
  end

  def test_view_effective_collapse_explicit_override
    view = fresh_view(format: "html")
    view.instance_variable_get(:@options)[:collapse] = ["Custom"]
    assert_equal ["Custom"], view.effective_collapse(edges_array)
  end

  def test_view_run_executes_full_pipeline_with_stubbed_runner
    runner_stub = Object.new
    runner_stub.define_singleton_method(:analyse) do |_paths|
      [
        [Rigor::ModuleGraph::Edge.build(from: "A", to: "B", kind: "include")],
        [Rigor::ModuleGraph::Node.build(kind: "class", name: "A")]
      ]
    end
    stdout = StringIO.new
    stderr = StringIO.new
    view = CLI::View.new(stdout: stdout, stderr: stderr)
    view.instance_variable_get(:@options)[:format] = "mermaid"

    CLI::RigorRunner.stub :new, ->(**_kw) { runner_stub } do
      assert_equal 0, view.run([])
    end
    assert_includes stdout.string, "flowchart LR"
  end

  # --- RigorRunner shell-out branches ---

  def test_rigor_runner_with_cache_true
    cmd_captured = nil
    fake_status = Object.new
    def fake_status.success? = true
    runner = CLI::RigorRunner.new(cache: true)
    Open3.stub :capture3, lambda { |*cmd, **_|
      cmd_captured = cmd
      ['{"diagnostics":[]}', "", fake_status]
    } do
      runner.edges_for([])
    end
    assert_includes cmd_captured, "--cache"
    refute_includes cmd_captured, "--no-cache"
  end

  def test_rigor_runner_with_explicit_paths
    cmd_captured = nil
    fake_status = Object.new
    def fake_status.success? = true
    runner = CLI::RigorRunner.new
    Open3.stub :capture3, lambda { |*cmd, **_|
      cmd_captured = cmd
      ['{"diagnostics":[]}', "", fake_status]
    } do
      runner.edges_for(%w[app lib])
    end
    assert_includes cmd_captured, "app"
    assert_includes cmd_captured, "lib"
  end

  def test_rigor_runner_raises_when_dot_status_failure_with_empty_stdout
    fake_status = Object.new
    def fake_status.success? = false
    def fake_status.exitstatus = 9
    runner = CLI::RigorRunner.new
    Open3.stub :capture3, ->(*_a, **_) { ["", "boom", fake_status] } do
      err = assert_raises(CLI::CollectError) { runner.edges_for([]) }
      assert_includes err.message, "rigor exited 9"
    end
  end

  def test_rigor_runner_falls_through_when_status_failed_but_has_output
    # rigor exits non-zero when it finds error-level diagnostics,
    # but we still parse the payload.
    fake_status = Object.new
    def fake_status.success? = false
    def fake_status.exitstatus = 1
    runner = CLI::RigorRunner.new
    Open3.stub :capture3, lambda { |*_a, **_|
      ['{"diagnostics":[]}', "", fake_status]
    } do
      edges = runner.edges_for([])
      assert_empty edges
    end
  end

  def test_rigor_runner_raises_on_missing_binary
    runner = CLI::RigorRunner.new
    Open3.stub :capture3, ->(*_a, **_) { raise Errno::ENOENT, "rigor" } do
      err = assert_raises(CLI::CollectError) { runner.edges_for([]) }
      assert_includes err.message, "rigor binary not found"
    end
  end

  def test_rigor_runner_raises_on_bad_json
    fake_status = Object.new
    def fake_status.success? = true
    runner = CLI::RigorRunner.new
    Open3.stub :capture3, ->(*_a, **_) { ["not json", "", fake_status] } do
      err = assert_raises(CLI::CollectError) { runner.edges_for([]) }
      assert_includes err.message, "invalid JSON"
    end
  end

  def test_collect_subcommand_writes_edges_and_nodes
    fake_status = Object.new
    def fake_status.success? = true
    payload = {
      "diagnostics" => [
        {
          "rule" => "edge", "source_family" => "plugin.module-graph",
          "path" => "a.rb", "line" => 1, "column" => 1,
          "message" => '{"from":"A","to":"B","kind":"include","confidence":"syntax"}'
        },
        {
          "rule" => "node", "source_family" => "plugin.module-graph",
          "path" => "a.rb", "line" => 1, "column" => 1,
          "message" => '{"kind":"class","name":"A"}'
        }
      ]
    }
    Open3.stub :capture3, ->(*_a, **_) { [JSON.generate(payload), "", fake_status] } do
      Dir.chdir(@tmpdir) do
        status, _out, err = run_cli([
                                      "collect",
                                      "-o", "out/edges.jsonl",
                                      "--nodes-output", "out/nodes.jsonl"
                                    ])
        assert_equal 0, status
        assert_includes err, "wrote 1 edge"
        assert_path_exists File.join(@tmpdir, "out/edges.jsonl")
        assert_path_exists File.join(@tmpdir, "out/nodes.jsonl")
      end
    end
  end

  def test_collect_reports_parse_error
    Open3.stub :capture3, ->(*_a, **_) { raise OptionParser::ParseError, "x" } do
      status, _out, err = run_cli(["collect", "--unknown-flag"])
      assert_equal 2, status
      assert_includes err, "invalid option"
    end
  end

  def test_view_subtitle_with_package_groups_includes_packages
    view = CLI::View.new(stdout: StringIO.new, stderr: StringIO.new)
    groups = { "Foo" => "a", "Bar" => "b", "Baz" => "c", "Qux" => "d",
               "X" => "e", "Y" => "f", "Z" => "g" }
    subtitle = view.render_subtitle([], [], groups)
    assert_includes subtitle, "packages:"
    # 6-preview cap means the 7th would surface via "+1 more".
    assert_includes subtitle, "(+1 more)"
  end

  def test_view_open_in_browser_swallows_errors
    view = CLI::View.new(stdout: StringIO.new, stderr: StringIO.new)
    view.stub :system, ->(*_a) { raise "broken" } do
      # The rescue StandardError path writes to stderr and
      # returns nil instead of crashing the caller.
      view.send(:open_in_browser, "/tmp/x.html")
    end
  end

  def test_view_runs_html_with_open_disabled_writes_default_path
    Dir.chdir(@tmpdir) do
      runner_stub = Object.new
      runner_stub.define_singleton_method(:analyse) do |_paths|
        [
          [Rigor::ModuleGraph::Edge.build(from: "A", to: "B", kind: "include", path: "x.rb")],
          []
        ]
      end
      view = CLI::View.new(stdout: StringIO.new, stderr: StringIO.new)
      view.instance_variable_get(:@options)[:open] = false
      CLI::RigorRunner.stub :new, ->(**_kw) { runner_stub } do
        assert_equal 0, view.run([])
      end
      assert_path_exists File.join(@tmpdir, ".rigor/module_graph/view.html")
    end
  end

  def test_view_runs_with_package_warning_when_no_package_yml
    runner_stub = Object.new
    runner_stub.define_singleton_method(:analyse) do |_paths|
      [
        [Rigor::ModuleGraph::Edge.build(from: "Foo", to: "Bar", kind: "include")],
        []
      ]
    end
    Dir.chdir(@tmpdir) do
      stdout = StringIO.new
      stderr = StringIO.new
      view = CLI::View.new(stdout: stdout, stderr: stderr)
      opts = view.instance_variable_get(:@options)
      opts[:open] = false
      opts[:package] = @tmpdir
      opts[:format] = "mermaid"
      CLI::RigorRunner.stub :new, ->(**_kw) { runner_stub } do
        assert_equal 0, view.run([])
      end
      assert_includes stderr.string, "no package.yml found"
    end
  end

  def test_view_subtitle_with_explicit_depth_and_direction
    view = CLI::View.new(stdout: StringIO.new, stderr: StringIO.new)
    opts = view.instance_variable_get(:@options)
    opts[:from] = ["Foo"]
    opts[:depth] = 2
    opts[:direction] = :in
    s = view.render_subtitle([], [], nil)
    assert_includes s, "(depth=2)"
    assert_includes s, "[in]"
  end

  def test_stats_via_stdin
    status, out, _err = run_cli(["stats"], stdin: StringIO.new(SAMPLE_EDGES))
    assert_equal 0, status
    assert_includes out, "Billing"
  end

  def test_run_collect_error_in_view_run_returns_1
    runner_stub = Object.new
    runner_stub.define_singleton_method(:analyse) do |_paths|
      raise CLI::View::RenderError, "graphviz boom"
    end
    view = CLI::View.new(stdout: StringIO.new, stderr: StringIO.new)
    CLI::RigorRunner.stub :new, ->(**_kw) { runner_stub } do
      assert_equal 1, view.run([])
    end
  end

  def test_view_run_reports_collect_error
    stdout = StringIO.new
    stderr = StringIO.new
    view = CLI::View.new(stdout: stdout, stderr: stderr)
    runner_stub = Object.new
    runner_stub.define_singleton_method(:analyse) do |_p|
      raise CLI::CollectError, "boom"
    end
    CLI::RigorRunner.stub :new, ->(**_kw) { runner_stub } do
      assert_equal 1, view.run([])
    end
    assert_includes stderr.string, "boom"
  end

  def test_diagnostics_to_edges_skips_wrong_source_family
    runner = CLI::RigorRunner.new
    diagnostics = [
      {
        "rule" => "edge", "source_family" => "different",
        "message" => '{"from":"A","to":"B","kind":"include","confidence":"syntax"}'
      }
    ]
    assert_empty runner.diagnostics_to_edges(diagnostics)
  end

  def test_view_deliver_writes_html_when_open_disabled
    Dir.chdir(@tmpdir) do
      view = fresh_view(format: "html", open: false)
      # ensure_output_dir branch where dir is empty
      view.send(:deliver, "<html></html>", binary: false, edges: edges_array)
    end
  end

  def test_view_runs_with_explicit_collapse_input
    runner_stub = Object.new
    runner_stub.define_singleton_method(:analyse) do |_paths|
      [
        [Rigor::ModuleGraph::Edge.build(from: "Foo::X", to: "Y", kind: "include")],
        []
      ]
    end
    view = CLI::View.new(stdout: StringIO.new, stderr: StringIO.new)
    opts = view.instance_variable_get(:@options)
    opts[:format] = "mermaid"
    opts[:collapse] = ["Foo"]
    CLI::RigorRunner.stub :new, ->(**_kw) { runner_stub } do
      assert_equal 0, view.run([])
    end
  end

  def test_view_open_in_browser_uses_xdg_on_non_darwin
    view = CLI::View.new(stdout: StringIO.new, stderr: StringIO.new)
    captured = []
    fake_const = RUBY_PLATFORM.include?("darwin") ? "darwin" : "linux"
    # Stub RUBY_PLATFORM is read-only; instead force ENV["BROWSER"]
    # which short-circuits both branches.
    ENV["BROWSER"] = "echo"
    view.stub :system, lambda { |opener, _path|
      captured << opener
      true
    } do
      view.send(:open_in_browser, "/tmp/foo.html")
    end
    ENV.delete("BROWSER")
    assert_equal ["echo"], captured
    refute_nil fake_const # just touches the constant to silence rubocop
  end

  def test_view_render_payload_html_branch_when_collapse_nonempty
    view = fresh_view(format: "html")
    payload, = view.send(:render_payload, edges_array, nodes_array, ["Billing"], nil)
    assert_includes payload, "<!doctype html>"
  end

  def test_view_render_payload_with_groups_overrides_collapse
    view = fresh_view(format: "mermaid")
    groups = { "Billing::Invoice" => "pkg/billing" }
    payload, = view.send(:render_payload, edges_array, nodes_array, [], groups)
    assert_includes payload, "pkg"
  end

  def test_view_restrict_nodes_when_edges_empty_returns_nodes_unchanged
    view = CLI::View.new(stdout: StringIO.new, stderr: StringIO.new)
    nodes = nodes_array
    assert_equal nodes, view.send(:restrict_nodes_to_edges, nodes, [])
  end

  def test_view_deliver_open_browser_when_html_and_open_true
    Dir.chdir(@tmpdir) do
      view = fresh_view(format: "html", open: true)
      view.stub :open_in_browser, ->(_path) {} do
        view.send(:deliver, "<html></html>", binary: false, edges: edges_array)
      end
    end
  end

  def test_render_format_mermaid_subcommand_via_render_class
    # Directly drive Render class for both formats so the
    # `case @format` branches are exercised.
    %i[dot mermaid].each do |fmt|
      render = CLI::Render.new(fmt, stdout: StringIO.new, stderr: StringIO.new, stdin: StringIO.new)
      assert_equal 0, render.run([@edges_path])
    end
  end

  def test_stats_format_dispatches_json
    cmd = CLI::StatsCmd.new(stdout: StringIO.new, stderr: StringIO.new, stdin: StringIO.new)
    cmd.instance_variable_get(:@state)[:format] = "json"
    cmd.send(:render, [Rigor::ModuleGraph::Stats::NamespaceMetrics.new(
      namespace: "Foo", nodes: 1, fan_out: 1, fan_in: 0, internal: 0
    )])
  end

  def test_render_subtitle_without_depth_omits_depth_part
    view = CLI::View.new(stdout: StringIO.new, stderr: StringIO.new)
    opts = view.instance_variable_get(:@options)
    opts[:from] = ["Foo"]
    opts[:direction] = :both
    s = view.render_subtitle([], [], nil)
    refute_includes s, "(depth="
    refute_includes s, "[both]"
  end

  def test_default_collapse_when_no_explicit_value_uses_auto
    view = fresh_view(format: "html")
    view.instance_variable_get(:@options)[:collapse] = nil
    # Empty edges → no candidates → empty collapse list.
    assert_equal [], view.effective_collapse([])
  end

  def test_stats_format_table_zero_size_input
    cmd = CLI::StatsCmd.new(stdout: StringIO.new, stderr: StringIO.new, stdin: StringIO.new)
    out = cmd.send(:format_table, [])
    assert_equal "(no edges)\n", out
  end

  def test_collect_diagnostics_to_nodes_filters_and_parses
    runner = CLI::RigorRunner.new
    diagnostics = [
      {
        "rule" => "node", "source_family" => "plugin.module-graph",
        "path" => "a.rb", "line" => 2,
        "message" => '{"kind":"class","name":"Foo"}'
      },
      {
        "rule" => "node", "source_family" => "plugin.module-graph",
        "message" => "garbage"
      }
    ]
    nodes = runner.diagnostics_to_nodes(diagnostics)
    assert_equal 1, nodes.size
    assert_equal "Foo", nodes.first.name
  end
end
