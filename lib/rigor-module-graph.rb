# frozen_string_literal: true

# == rigor-module-graph
#
# Class/module/constant dependency graph for Ruby projects, built
# on Rigor[https://rigor.typedduck.fail/]. Loading this file pulls
# in every public piece of the gem: the Edge value type, the
# Analyzer, the renderers (Dot/Mermaid/CycleDetector), and — when
# +Rigor::Plugin::Base+ is already defined — the Rigor plugin that
# wires the node rules.
#
# Most users interact with this gem through the +rigor-module-graph+
# command-line wrapper (see Rigor::ModuleGraph::CLI), not by
# requiring it directly.

require_relative "rigor/module_graph/version"
require_relative "rigor/module_graph/edge"
require_relative "rigor/module_graph/node"
require_relative "rigor/module_graph/constant_name"
require_relative "rigor/module_graph/zeitwerk_resolver"
require_relative "rigor/module_graph/inflector"
require_relative "rigor/module_graph/visibility_map"
require_relative "rigor/module_graph/analyzer"
require_relative "rigor/module_graph/dot"
require_relative "rigor/module_graph/mermaid"
require_relative "rigor/module_graph/cycle_detector"
require_relative "rigor/module_graph/reachability"
require_relative "rigor/module_graph/stats"
require_relative "rigor/module_graph/packwerk_overlay"
require_relative "rigor/module_graph/uml/class_diagram"
require_relative "rigor/module_graph/html_view"
require_relative "rigor/module_graph/status_reporter"
require_relative "rigor/module_graph/viewer/html"
require_relative "rigor/module_graph/plugin"
