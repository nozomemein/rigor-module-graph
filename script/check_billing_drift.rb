# Regenerates the showcased `examples/billing/` artefacts and
# fails if any drift from the committed copies. The CI gate
# behind this catches the "edited build.rb (or anything in
# `lib/`) but forgot to refresh the example output" mistake
# before the PR lands.
#
# Diff is normalised before comparison so environment-specific
# noise (e.g. the graphviz version comment in SVG) doesn't
# trigger false positives across CI / local runs.
#
# Usage:
#   ruby script/check_billing_drift.rb [--commit]
#
#   --commit  Write the freshly-rendered files into place
#             instead of failing on drift. Maintainer
#             convenience for "just refresh, don't lecture me".

require "fileutils"

REPO_ROOT = File.expand_path("..", __dir__)
BILLING_DIR = File.join(REPO_ROOT, "examples", "billing")
BUILD_RB = File.join(BILLING_DIR, "build.rb")

# Files build.rb produces that this script checks for drift.
# `graph.svg` is deliberately NOT in the list — Graphviz `dot`
# emits subtly different layout coordinates across versions
# (Ubuntu apt's graphviz vs the maintainer's locally-installed
# 14.1.2 produce ~8% byte-level diffs in identical input). The
# committed `graph.svg` is treated as a hero image the
# maintainer regenerates locally and commits intentionally,
# not a deterministically-rebuildable CI artefact. HTML files
# are the genuine drift targets — they're cytoscape /
# mermaid bytes plus our deterministic JSON payload, so a real
# build.rb / lib/ change shifts them and only them.
TRACKED_ARTEFACTS = %w[
  index.html
  class-diagram.html
].freeze

# Per-file normalisers strip environment-specific bytes that
# would otherwise drift across runs without indicating a real
# change to the artefact.
PASSTHROUGH = ->(bytes) { bytes }

# Absolute paths to the billing example directory leak into
# the rendered HTML via the page subtitle (`18 edge(s) from
# /home/runner/work/.../examples/billing`). Strip everything
# up to and including `examples/billing` so the comparison
# survives macOS-locally vs ubuntu-CI checkouts living at
# different prefixes.
BILLING_PATH_RE = %r{[^"<>\s]*examples/billing}

HTML_NORMALISER = lambda do |bytes|
  bytes.gsub(BILLING_PATH_RE, "examples/billing")
end

NORMALISERS = {
  "index.html" => HTML_NORMALISER,
  "class-diagram.html" => HTML_NORMALISER
}.freeze

def normalise(filename, bytes)
  (NORMALISERS[filename] || PASSTHROUGH).call(bytes)
end

def regenerate
  Dir.chdir(BILLING_DIR) do
    system({ "BUNDLE_GEMFILE" => File.join(REPO_ROOT, "Gemfile") },
           "bundle", "exec", "ruby", BUILD_RB,
           out: $stderr, err: $stderr) || abort("build.rb failed")
  end
end

def snapshot
  TRACKED_ARTEFACTS.each_with_object({}) do |name, h|
    path = File.join(BILLING_DIR, name)
    h[name] = normalise(name, File.binread(path))
  end
end

mode = ARGV.first

before = snapshot
regenerate
after = snapshot

drift = TRACKED_ARTEFACTS.reject { |name| before[name] == after[name] }

if drift.empty?
  puts "examples/billing: all #{TRACKED_ARTEFACTS.size} artefact(s) up to date"
  exit 0
end

if mode == "--commit"
  puts "examples/billing: regenerated"
  drift.each { |name| puts "  #{name}" }
  exit 0
end

# Restore the committed bytes before printing the diff, so the
# working tree isn't dirtied by a check that's supposed to be
# read-only.
TRACKED_ARTEFACTS.each do |name|
  File.binwrite(File.join(BILLING_DIR, name), before[name])
end

warn "examples/billing: drift detected in #{drift.size} artefact(s)"
drift.each do |name|
  before_size = before[name].bytesize
  after_size = after[name].bytesize
  warn "  #{name}: #{before_size} → #{after_size} bytes (normalised)"
end
warn
warn "Run `bundle exec ruby script/check_billing_drift.rb --commit`"
warn "to regenerate locally, then commit the result."
exit 1
