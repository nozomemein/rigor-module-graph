# rigor-module-graph

Class/module/constant dependency graph for Ruby projects, built on
[Rigor](https://rigor.typedduck.fail/). The class-level counterpart
to Packwerk/Graphwerk: where those look at package boundaries, this
looks at the Ruby nominal graph — inheritance, `include`/`prepend`/
`extend`, and (later) constant references.

![billing example](examples/billing/graph.svg)

The screenshot above is from `examples/billing/`. Open
`examples/billing/index.html` for the live Mermaid version.

## What this actually does

In principle this is a static-analysis tool that turns Ruby source
into a graph whose **nodes are classes / modules / constants** and
whose **edges are the references the language itself spells out**.

The pipeline:

1. Rigor parses Ruby into an AST with Prism.
2. The plugin's `node_rule`s pick up `ClassNode` / `CallNode` /
   `ConstantReadNode` and friends.
3. Each interesting node becomes one or more edges:
   - `class A < B` → `A -> B / inherits`
   - `include M` → `A -> M / include`
   - a `Money` constant reference → `A -> Money / const_ref`
     (Phase 2 and later)
4. `from` is the lexical owner, assembled by walking
   `context.ancestors` — so `class Billing::Invoice` produces
   `Billing::Invoice`, not just `Invoice`.
5. `to` is resolved through a confidence ladder: syntax →
   Zeitwerk convention → Rigor type information. Whatever we
   couldn't pin down stays visible in the `confidence` field
   rather than being dropped.
6. Every edge ships as a Rigor `:info` diagnostic. The `collect`
   subcommand filters them on `rule == "edge"` and writes JSONL.
7. DOT, SVG, Mermaid, and cycle detection are all derived from
   that JSONL.

So we are not watching what Ruby *does at runtime*. We're reading
Ruby's *named structure* and reconstructing, approximately, "which
constants depend on which other constants".

### This is not a call graph

We do not track who `foo.bar` resolves to at runtime. We track
the fact that the `Billing::Invoice` name depends on the
`ApplicationRecord` / `Auditable` / `Money` names. That is a
**nominal dependency graph** — a compiler-front-end-style view
of the project's syntactic and lexical structure, projected into
edges with explicit confidence.

Not re-implementing Ruby constant lookup is deliberate. For
understanding a Rails codebase's shape, it's more useful to leave
each edge tagged `syntax` / `zeitwerk` / `rigor_type` /
`unresolved` than to fake a `resolved` answer and silently get it
wrong.

## Status

- **Phase 0 (spike)** ✅: validated the Rigor plugin API and
  locked in the `:info` diagnostic output channel.
- **Phase 1 (MVP)** ✅: `inherits` / `include` / `prepend` /
  `extend` edges, DOT / Mermaid / cycles output, dedup,
  Rigor-driven AST walk.
- **Phase 2** ✅: Zeitwerk path → constant inference (elevates
  confidence to `zeitwerk` when path agrees with lexical owner),
  `const_ref` edges from method-body references behind an
  `include_constant_refs` flag, namespace collapse in both Dot
  and Mermaid.
- **Phase 3** ✅: when a mixin argument is not a constant,
  `scope.type_of` is consulted — a `Singleton[X]` carrier
  promotes the edge to `confidence: "rigor_type"`. Failures
  degrade to `confidence: "unresolved"` with the source slice
  preserved in `raw`.
- **Phase 4** ✅: per-namespace fan-in / fan-out report
  (`stats` subcommand, text + JSON), Packwerk overlay
  (`--package` / `--package-root`) so DOT/Mermaid/view cluster by
  `packages/<name>/package.yml` boundaries instead of (or in
  addition to) the Ruby namespace.
- **Phase 5** ✅: UML-style class diagram output. `collect` also
  writes `nodes.jsonl` (class / module declarations + methods +
  attributes + Ruby visibility). `class-diagram` renders Mermaid
  `classDiagram` syntax with member visibility glyphs and
  cardinality on Rails associations (`has_many` / `belongs_to` /
  `has_one` / `has_and_belongs_to_many`).
- See `plan.md` for the full picture.

## Installation

Via Bundler:

```ruby
# Gemfile
gem "rigor-module-graph"
```

```sh
bundle install
```

Or globally:

```sh
gem install rigor-module-graph
```

Both paths pull in `rigortype` and `rbs ~> 4.0` transitively. The
`rbs ~> 4.0` constraint is the key one: rigortype 0.2.x calls
`RBS::Environment::ClassEntry#each_decl`, which only exists in
rbs 4.x. The Ruby 4.0 stdlib bundles rbs 3.10 as a default gem,
so installing `rigor-module-graph` (which depends on rbs 4.x)
makes RubyGems activate the 4.x gem at run time and the
analyzer stays alive.

## Configuration

Add the plugin to your project's `.rigor.yml`:

```yaml
target_ruby: '4.0'
paths:
  - app
  - lib
plugins:
  - gem: rigor-module-graph
    config:
      rails_zeitwerk: true
      autoload_paths:
        - app/models
        - app/controllers
        - app/services
        - app/jobs
        - lib
      concern_dirs:
        - app/models/concerns
        - app/controllers/concerns
      include_constant_refs: false
```

Every key shown is the default. Set `include_constant_refs: true`
to emit `const_ref` edges from constant references inside method
bodies. Set `rails_zeitwerk: false` to keep every edge at
`confidence: "syntax"` and skip path-based owner inference.

## Usage

### One-shot: `view`

The default subcommand analyses the current directory, writes a
self-contained Mermaid HTML report under `.rigor/module_graph/`,
and opens it in your browser. No flags needed for a Rails-shaped
project.

```sh
cd path/to/your/project
bundle exec rigor-module-graph         # same as: rigor-module-graph view
```

Useful flags:

```sh
# Don't open the browser (just write the HTML)
rigor-module-graph view --no-open

# Pick a different output format — html (default) opens a viewer
# in the browser; everything else streams to stdout unless `-o`
# is given.
rigor-module-graph view --no-open --output mermaid       > graph.mmd
rigor-module-graph view --no-open --output dot           > graph.dot
rigor-module-graph view --no-open --output svg           > graph.svg
rigor-module-graph view --no-open --output class-diagram > class.mmd
rigor-module-graph view --output svg -o graph.svg

# Focus on what's around one or a few constants (Mermaid can't
# render 1000+-node graphs cleanly — this is the escape hatch)
rigor-module-graph view --from Article --depth 5
rigor-module-graph view --from Article --depth 5 --direction out
rigor-module-graph view --from Billing::Invoice,Billing::Payment --depth 2

# Pick your own collapse list (default: auto-detect top-level
# namespaces with ≥ 3 members)
rigor-module-graph view --collapse Billing,Auth
rigor-module-graph view --no-collapse

# Same kind / confidence filters as the lower-level commands
rigor-module-graph view --kind inherits,include
rigor-module-graph view --confidence syntax,zeitwerk

# Cluster by Packwerk packages (auto-detects package.yml under cwd)
rigor-module-graph view --package
rigor-module-graph view --package-root /path/to/repo
```

`--direction` controls how the +--from+ walk follows edges:

| direction | meaning                                |
|-----------|----------------------------------------|
| `out`     | only "what does Article depend on"     |
| `in`      | only "what depends on Article"         |
| `both`    | both (default)                         |

`--edge-scope` controls which edges survive once the BFS finishes:

| edge-scope | meaning                                                    |
|------------|------------------------------------------------------------|
| `cluster`  | keep every edge whose endpoints both fall in the reachable set (default — good for "show me the Article neighbourhood as a cluster") |
| `walk`     | keep only the edges the BFS actually traversed (good for "show me what depends on Article and nothing else"; drops sibling edges like `Foo inherits ApplicationRecord` that just happen to share a base class with reachable nodes) |

A 1-hop `--from Article --direction out --edge-scope walk` returns
exactly the edges whose `from` is `Article`, never the sibling
`inherits ApplicationRecord` of a reached node.

### Lower-level pipeline

The pipeline `view` runs is also exposed as discrete subcommands
when you want JSONL on disk or a pipeable text output:

```sh
# Run `rigor check` and write edges JSONL (default: .rigor/module_graph/edges.jsonl)
bundle exec rigor-module-graph collect

# Render the graph
bundle exec rigor-module-graph dot     .rigor/module_graph/edges.jsonl > graph.dot
bundle exec rigor-module-graph mermaid .rigor/module_graph/edges.jsonl > graph.mmd
dot -Tsvg graph.dot -o graph.svg

# Detect cycles (exit 1 if any are found)
bundle exec rigor-module-graph cycles  .rigor/module_graph/edges.jsonl

# Per-namespace fan-in / fan-out report
bundle exec rigor-module-graph stats   .rigor/module_graph/edges.jsonl
bundle exec rigor-module-graph stats --format json --limit 10 edges.jsonl

# UML class diagram (Mermaid classDiagram). Reads edges + the
# sibling nodes.jsonl that `collect` writes.
bundle exec rigor-module-graph class-diagram .rigor/module_graph/edges.jsonl > class.mmd
bundle exec rigor-module-graph class-diagram --no-private --no-attributes edges.jsonl
```

`collect` shells out to `rigor check --format json --no-cache` and
filters diagnostics on `source_family == "plugin.module-graph"` +
`rule == "edge"`, so re-running is deterministic and there's no
on-disk side-effect from the plugin itself.

`dot` / `mermaid` / `cycles` accept a file argument or read stdin.

### Filters and collapse

All three reader subcommands accept the same filter flags. They
prune the edge set before rendering / detecting; the JSONL on
disk is untouched.

```sh
# Drop noisy const_ref / unresolved edges
bundle exec rigor-module-graph dot --kind inherits,include,prepend,extend edges.jsonl

# Only the edges we're sure about
bundle exec rigor-module-graph dot --confidence syntax,zeitwerk,rigor_type edges.jsonl

# Fold every Billing::* node into one cluster (Dot subgraph_cluster_; Mermaid subgraph)
bundle exec rigor-module-graph dot     --collapse Billing,Auth edges.jsonl
bundle exec rigor-module-graph mermaid --collapse Billing edges.jsonl

# Restrict the graph to the neighbourhood of one or a few
# constants (works on dot / mermaid / cycles too)
bundle exec rigor-module-graph dot     --from Article --depth 5 edges.jsonl
bundle exec rigor-module-graph mermaid --from Article --depth 5 --direction out edges.jsonl

# Cluster by Packwerk packages instead of by namespace
bundle exec rigor-module-graph dot     --package edges.jsonl  # cwd
bundle exec rigor-module-graph mermaid --package-root /path/to/repo edges.jsonl

# Cycles that stay within structural edges only
bundle exec rigor-module-graph cycles --kind inherits,include edges.jsonl
```

## Edge format

Each edge in the JSONL file looks like:

```json
{"from":"Billing::Invoice","to":"ApplicationRecord","kind":"inherits","path":"app/models/billing/invoice.rb","line":2,"column":3,"confidence":"syntax"}
```

- `kind`: `inherits` / `include` / `prepend` / `extend` /
  `const_ref` (the last one is reserved for Phase 2).
- `confidence`: `syntax` / `zeitwerk` / `rigor_type` /
  `unresolved`. MVP only emits `syntax`.

The renderers dedup by `(from, to, kind, confidence)` so two
`include Foo` on the same class across files collapse to one edge.

## Development

```sh
bundle install
bundle exec lefthook install      # wire pre-commit / pre-push hooks
bundle exec rake test
UPDATE_SNAPSHOTS=1 bundle exec rake test   # to refresh snapshots
bundle exec rake coverage         # C2 (branch) coverage report under ./coverage
```

### Git hooks

`lefthook.yml` wires four checks. The split is "fast on every
commit, full suite on push":

| hook       | command       | scope                          |
|------------|---------------|--------------------------------|
| pre-commit | rubocop       | staged Ruby files              |
| pre-commit | betterleaks   | staged content, secret scan    |
| pre-commit | rigor check   | staged Ruby files              |
| pre-push   | minitest      | full `rake test`               |

The three pre-commit checks run in parallel; on this repo they
finish in ~1 second together. `betterleaks` is a binary (`brew
install betterleaks` on macOS) — the others come in through
Bundler. `rubocop` re-stages autocorrected files.

Skip a hook ad-hoc with `LEFTHOOK_EXCLUDE=<command>` (e.g.
`LEFTHOOK_EXCLUDE=rigor git commit ...`).

The test suite covers:

- `ConstantName`, `Edge`, `Analyzer`, `CycleDetector`,
  `ZeitwerkResolver` as unit tests
- `Dot`, `Mermaid` rendering via `minitest-snapshot`
- An integration test that boots the real `rigor` binary against
  `test/fixtures/rails_app/` and snapshots the edges JSONL

## Documentation

The public API is documented with RDoc. Generate it locally and
browse:

```sh
bundle exec rake rdoc            # writes ./doc
bundle exec rake rdoc:preview    # writes ./doc and opens index.html
bundle exec rake rdoc:server     # serves on http://localhost:8808 via `ri --server`
```

`rake rdoc:preview` honours `$BROWSER` if set; otherwise it falls
back to `open` on macOS and `xdg-open` elsewhere.

Online docs follow whatever rubydoc.info publishes from the latest
release: <https://rubydoc.info/gems/rigor-module-graph>.

## Compatibility

- Ruby `>= 4.0.0, < 4.1`
- rigortype `~> 0.2.1`
- rbs `~> 4.0`

## Phase 5 limitations

- The visibility tracker honours bare `private` / `public` /
  `protected` keywords. The explicit symbol form (`private :foo,
  :bar`), `private_class_method`, and `class << self` blocks
  fall through and read as `public`.
- The Rails inflector is the tiny one this gem ships. For
  irregular plurals not in the bundled table (`mice`, `people`,
  `feet`, `children`, …), or for project-specific ones, prefer
  `class_name: "Foo"` on the association so the resolved name is
  exact rather than guessed.
- Mermaid 10.x's `classDiagram` parser silently rejects the
  document when the UML `<<module>>` annotation co-exists with
  the `class Foo["Label"]` form needed for namespaced constants,
  so module nodes carry a `«module»` label suffix instead of the
  UML annotation glyph. Drop-in fix once Mermaid stabilises that
  combination.
