#!/usr/bin/env ruby
# frozen_string_literal: true

# Regenerate the billing example's committed artefacts:
# graph.svg (Graphviz) and index.html (the standalone Mermaid
# viewer). The intermediate edges.jsonl / graph.mmd / graph.dot
# live under .rigor/ and are gitignored.
#
# Run from any working directory:
#
#   ruby examples/billing/build.rb
#   bundle exec ruby examples/billing/build.rb
#
# Day-to-day, prefer `rigor-module-graph view` for a one-shot
# browser preview of any project. This script exists so the repo
# stays self-contained for GitHub viewers.

require "fileutils"
require "open3"

HERE = File.expand_path(__dir__)
GEM_ROOT = File.expand_path("../..", HERE)
EXE = File.join(GEM_ROOT, "exe/rigor-module-graph")
ENV["BUNDLE_GEMFILE"] = File.join(GEM_ROOT, "Gemfile")

Dir.chdir(HERE)

def step(label)
  warn "==> #{label}"
  yield
end

def sh_to_file!(*cmd, out:)
  stdout, stderr, status = Open3.capture3(*cmd)
  raise "command failed (#{status.exitstatus}): #{cmd.inspect}\n#{stderr}" unless status.success?

  File.write(out, stdout)
end

step "collect (rigor check + filter)" do
  system("bundle", "exec", EXE, "collect", exception: true)
end

step "render mermaid (collapsed under Billing)" do
  sh_to_file!(
    "bundle", "exec", EXE, "mermaid",
    "--collapse", "Billing",
    ".rigor/module_graph/edges.jsonl",
    out: "graph.mmd"
  )
end

step "render dot (collapsed under Billing)" do
  sh_to_file!(
    "bundle", "exec", EXE, "dot",
    "--collapse", "Billing",
    ".rigor/module_graph/edges.jsonl",
    out: "graph.dot"
  )
end

if `command -v dot`.strip != ""
  step "render svg via Graphviz" do
    system("dot", "-Tsvg", "graph.dot", "-o", "graph.svg", exception: true)
  end
else
  warn "==> skip svg (graphviz `dot` not on PATH)"
end

step "rebuild index.html (Mermaid embedded inline)" do
  $LOAD_PATH.unshift File.join(GEM_ROOT, "lib")
  require "rigor/module_graph/html_view"

  html = Rigor::ModuleGraph::HtmlView.render(
    title: "rigor-module-graph: billing example",
    subtitle: "Generated from examples/billing/app",
    mermaid_source: File.read("graph.mmd")
  )
  File.write("index.html", html)
end

warn "==> done. open #{File.join(HERE, "index.html")} in a browser."
