# Changelog

All notable changes to this project will be documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Categories:

- **Added** — new functionality
- **Changed** — behaviour of existing functionality
- **Deprecated** — scheduled for removal
- **Removed** — gone
- **Fixed** — bug fixes
- **Security** — security fixes
- **Performance** — user-visible performance improvements

## [Unreleased]

### Fixed

- RDoc generation now parses Markdown instead of RDoc syntax,
  so `![alt](path)` images in `README.md` / `CHANGELOG.md` /
  `docs/*.md` actually render. `Rake::Task[:rdoc]` is enhanced
  to copy `examples/billing/graph.svg` (and any future
  `RDOC_ASSET_PATHS` entries) into `doc/` so the generated site
  resolves the relative image references the README uses.

## [0.1.1] — 2026-06-20

First Action-driven publish. The 0.1.0 release happened via the
CLI fallback before the rubygems.org Trusted Publisher
registration was in place; 0.1.1 is the first version to land
through `release.yml`.

The user-visible code surface is intentionally tiny: the major
correctness fix (namespaced association resolution), the
Stats / Reachability / Edge perf rewrites, the SHA-pinned
workflows, the docs split, and the MIT `LICENSE.txt` all
already shipped in 0.1.0.

### Changed

- `--version` / `-v` / `version` now prints
  `rigor-module-graph X.Y.Z` instead of a bare `X.Y.Z`.
  Matches the convention `bundler --version` and `gh --version`
  use; bug reports pasted into chat are self-identifying.

## [0.1.0] — 2026-06-20

Initial release. Baseline shipping everything from the Phase 0
spike through Phase 5 (UML class diagram).

### Added

- **Phase 0**: Rigor plugin API spike against `rigortype 0.2.1`
  + `rbs ~> 4.0`, validating that `node_rule(Prism::ClassNode)`
  and friends work and locking in the `:info` diagnostic output
  channel.
- **Phase 1 (MVP)**: extraction of `inherits` / `include` /
  `prepend` / `extend` edges. `Rigor::ModuleGraph::Edge` (a
  `Data` subclass) with a JSONL writer, Graphviz DOT and Mermaid
  flowchart renderers, and cycle detection via an iterative
  Tarjan SCC.
- **Phase 2**: Zeitwerk-style path → constant inference
  (`ZeitwerkResolver`), namespace collapse in both renderers
  (DOT `subgraph cluster_*` and Mermaid `subgraph`), and
  `const_ref` edges from constant references inside method
  bodies (gated on `include_constant_refs`). Confidence promotes
  from `syntax` → `zeitwerk` when the path-inferred name agrees
  with the lexical owner.
- **Phase 3**: indirect mixin resolution via `scope.type_of`. A
  `Rigor::Type::Singleton` carrier lifts the edge to
  `confidence: "rigor_type"`; everything else degrades to
  `"unresolved"` with the source slice preserved in `raw`. CLI
  gains `--kind` and `--confidence` filters.
- **Phase 4**: `stats` subcommand reporting per-namespace
  fan-in / fan-out / internal / nodes (text and JSON, with
  `--grouping-depth N` and `--limit N`). Packwerk overlay
  (`--package` / `--package-root PATH`) discovers `package.yml`
  files recursively and uses them as the cluster boundary. The
  Dot / Mermaid renderers accept an explicit `groups:` mapping
  for arbitrary node → cluster assignments.
- **Phase 5**: UML-style class diagram. `collect` writes a
  sibling `nodes.jsonl` covering class / module declarations,
  method definitions, and `attr_*` attributes — with visibility
  tracked via the `VisibilityMap`'s bare `private` / `protected`
  / `public` keyword walk. Rails associations land as edges
  (`has_many` / `belongs_to` / `has_one` /
  `has_and_belongs_to_many`, with cardinality and a tiny
  Rails-style inflector that maps `:invoices → Invoice`). A new
  `Uml::ClassDiagram` renderer and `class-diagram` subcommand
  emit Mermaid `classDiagram` syntax; filters `--no-methods`,
  `--no-attributes`, `--public-only`, `--no-private`.
- **`view` one-shot subcommand**: `rigor-module-graph` with no
  args (or `view` explicitly) analyses the current directory,
  writes a self-contained HTML report under
  `.rigor/module_graph/`, and opens it in a browser. The
  `--output html|mermaid|dot|svg|class-diagram` flag switches
  format; non-html streams to stdout unless `-o PATH` is given.
- **Reachability filter** (`--from NAMES`, `--depth N`,
  `--direction in/out/both`) shared by every reader subcommand.
  Subsequent `--edge-scope cluster|walk` flag distinguishes
  "show the neighbourhood as a cluster" (default) from "show
  only the edges the BFS actually traversed" (Codex review
  confirmed naming and direction-both semantics).
- **Billing example** (`examples/billing/`): Customer /
  Invoice / Payment / LineItem + concerns. `build.rb` runs the
  same `view --output` pipeline that ships in the CLI, and
  commits `index.html`, `class-diagram.html`, `graph.svg`, and
  a `preview.png` so the GitHub view of the repo shows the
  rendered output directly.
- **RDoc** support via `rake rdoc` / `rake rdoc:preview` /
  `rake rdoc:server`.
- **minitest + minitest-snapshot** test harness. Snapshots
  refresh with `UPDATE_SNAPSHOTS=1 rake test`.
- **SimpleCov C2 (branch) coverage** measurement via
  `COVERAGE=1 rake test` or `rake coverage`. Baseline is 91.19%
  branch coverage (445 / 488 branches).
- **lefthook** wiring rubocop / betterleaks / rigor / zizmor on
  pre-commit and minitest on pre-push.
- **GitHub Actions**: `ci.yml` (test, lint, workflow-lint) and
  `release.yml` (`workflow_dispatch`-only, uses RubyGems trusted
  publishing — no long-lived API token).

### Performance

- `Stats.compute` rewritten as a single pass with a mutable
  per-namespace counter array instead of a `Data#with` cascade
  per edge. On 2016 edges this took the call from **139 ms to
  47 ms (3.0×)**.
- `Reachability.walk` swaps `Set` for `Hash<name, true>` +
  `Array` frontier, builds only the adjacency direction it
  actually needs, and the `:both`-direction `walked_edge_indexes`
  shares one pair of indexed adjacencies between its out-walk
  and in-walk. Cluster depth-3 outbound: **27 ms → 14 ms (1.9×)**;
  both direction: **35 ms → 19 ms (1.8×)**.
- `Edge#dedup_key` is now a generated Data member set once in
  `Edge.build` as a `-`-frozen joined string. Renderer dedup
  Hashes go from `Hash<Array,_>` to `Hash<String,_>`, which
  drove the **1.2×** Dot / Mermaid render gain.
- YJIT (`--yjit`) adds another ~1.5×. ZJIT measured between
  baseline and YJIT, and trailed baseline on Stats and
  CycleDetector — recommendation stays YJIT.

[Unreleased]: https://github.com/nozomemein/rigor-module-graph/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/nozomemein/rigor-module-graph/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/nozomemein/rigor-module-graph/releases/tag/v0.1.0
