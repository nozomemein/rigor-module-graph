# Design plan

A record of the decisions still load-bearing for the codebase.
Per-version progress lives in [`CHANGELOG.md`](../CHANGELOG.md);
current rough edges live in [`limitation.md`](limitation.md).

## Purpose

Extract the Ruby `class` / `module` / `constant` dependency
graph from a project, render it as Graphviz DOT (and SVG by
extension), Mermaid `flowchart`, and Mermaid `classDiagram`.

The angle is **nominal**: the unit is a Ruby constant, not a
package boundary (Packwerk / Graphwerk) and not a call site
(Rubrowser / RailRoady). Five edge kinds are extracted:

- `inherits` — `class A < B`
- `include` / `prepend` / `extend` — module mixins
- `const_ref` — a bare constant reference inside a method body
- `association` — `has_many` / `belongs_to` / `has_one` /
  `has_and_belongs_to_many`, with cardinality

## Edge model

Edges are serialised as JSONL. One file, one line per edge:

```json
{"from":"Billing::Invoice","to":"ApplicationRecord","kind":"inherits","path":"app/models/billing/invoice.rb","line":1,"confidence":"syntax"}
{"from":"Billing::Invoice","to":"Auditable","kind":"include","path":"app/models/billing/invoice.rb","line":3,"confidence":"zeitwerk"}
{"from":"Billing::Invoice","to":"Money","kind":"const_ref","path":"app/models/billing/invoice.rb","line":12,"confidence":"rigor_type"}
```

Fields:

- `from`, `to` — fully-qualified constant names. Relative and
  absolute (`::Foo`) forms collapse to the same node.
- `kind` — one of the five above.
- `path`, `line`, `column` — extraction site.
- `confidence` — see below.
- `raw` — the source slice for an unresolved edge, so a manual
  pass can sift the `unresolved` pile without re-parsing.

JSONL was chosen over a single graph blob to keep extraction
and rendering decoupled: `collect` writes edges once, the
renderers (`dot`, `mermaid`, `cycles`, `stats`, `class-diagram`,
`view`) each read the same file. Adding a renderer doesn't
touch extraction.

## Confidence ladder

Each edge carries one of four confidence levels. Promotions are
monotonic; demotion never happens.

| level | source |
|---|---|
| `syntax` | the AST said so directly — `class A < B`, `include Mod` |
| `zeitwerk` | path-to-constant inference agreed with the lexical name |
| `rigor_type` | `scope.type_of(arg)` returned a `Singleton[X]` carrier |
| `unresolved` | name resolution failed; the source slice is in `raw` |

The reason for keeping `unresolved` instead of dropping it: in
real codebases, the indirect mixin paths (DSLs, proc-fed module
arguments, `include some_variable`) are exactly where the
interesting cross-cutting structure lives. Dropping them leaves
the graph confidently wrong; keeping them lets the consumer
filter with `--confidence syntax,zeitwerk,rigor_type` when they
want a tight subset, or grep `raw` when they want the noisy
ones.

## Output channel: info diagnostic, not side-effect JSONL

The plugin emits each edge as a Rigor diagnostic with
`severity: :info`, `rule: "edge"`, `source_family:
"plugin.module-graph"`. A wrapper subcommand (`collect`) runs
`rigor check --format json --no-cache` and re-serialises the
matching diagnostics into `.rigor/module_graph/edges.jsonl`.

The alternative — having the plugin append to a JSONL file as a
side effect of `node_rule` — was rejected because it forces the
plugin to handle Rigor's per-file cache invalidation and
`--workers` Ractor-level write coordination by itself. The
info-diagnostic path inherits those guarantees from the engine
unchanged.

The known cost is that Rigor's per-file cache can skip a
`node_rule` whose source hasn't changed, suppressing the edge
re-emission. `collect` defaults to `--no-cache` to side-step
that; an opt-out exists for users who'd rather trade
correctness for speed on large repos.

## Owner resolution

Phase 0 surfaced a Prism quirk: for `class Billing::Invoice`,
`node.constant_path.full_name` returns `"Invoice"`, dropping
the outer `module Billing`. `context.enclosing_module` alone
isn't enough either — it gives the innermost lexical wrapper
but not the constant-path segments above it.

`ConstantName.lexical_owner` reconstructs the full name by
walking `context.ancestors` outer-to-inner, joining each
`ClassNode` / `ModuleNode`'s `constant_path` segment with
`"::"`. This handles all four shapes in one sweep:

- `class Foo` inside `module A` → `A::Foo`
- `class Foo::Bar` inside `module A` → `A::Foo::Bar`
- `class A::B` at top level → `A::B`
- bare `class Foo` at top level → `Foo`

`class << self` doesn't change the owner. Treating it as
`Foo.singleton_class` would create a phantom node with no
matching constant; under-reporting singleton method ownership
is preferable to emitting nodes the user can't look up.

## Association inference: prefer the lexical namespace

`has_many :invoices` inside `Billing::Customer` resolves to
`Billing::Invoice` in Rails via `compute_type`'s namespace
walk — `Invoice` (top-level) only wins when `Billing::Invoice`
doesn't exist. The full walk needs every constant in scope,
which we don't have at extraction time; the namespace default
is the right approximation:

1. `class_name:` always wins. Explicit overrides are exact.
2. With no override, prefix the owner's namespace:
   `Billing::Customer` + `:invoices` → `Billing::Invoice`.
3. Top-level owners keep the bare name unchanged.

The trade-off: when the user has `has_many :users` inside
`Billing::Customer` and means the top-level `::User`, the
inference is wrong. The escape hatch is the same
`class_name: "::User"` override Rails itself needs in that case.

## Architecture map

| file | role |
|---|---|
| `lib/rigor/module_graph/plugin.rb` | declares `node_rule`s, dispatches to `Analyzer` |
| `lib/rigor/module_graph/analyzer.rb` | the four edge-emission rules (`class_edges`, `module_edges`, `call_edges`, `constant_edges`) |
| `lib/rigor/module_graph/constant_name.rb` | owner reconstruction from `context.ancestors` |
| `lib/rigor/module_graph/zeitwerk_resolver.rb` | path → constant inference; promotes confidence to `zeitwerk` when the path agrees |
| `lib/rigor/module_graph/edge.rb` | the `Edge` Data type, JSONL reader / writer, dedup |
| `lib/rigor/module_graph/reachability.rb` | BFS subgraph filter (`--from`, `--depth`, `--direction`, `--edge-scope`) |
| `lib/rigor/module_graph/dot.rb` | DOT renderer with cluster collapse |
| `lib/rigor/module_graph/mermaid.rb` | Mermaid `flowchart` renderer |
| `lib/rigor/module_graph/uml/class_diagram.rb` | Mermaid `classDiagram` renderer |
| `lib/rigor/module_graph/cycle_detector.rb` | iterative Tarjan SCC |
| `lib/rigor/module_graph/stats.rb` | per-namespace fan-in / fan-out / internal |
| `lib/rigor/module_graph/packwerk_overlay.rb` | `package.yml` discovery → `{node => cluster_label}` |
| `lib/rigor/module_graph/html_view.rb` | the `view` subcommand's HTML wrapper |
| `lib/rigor/module_graph/cli.rb` | argument parsing, subcommand dispatch |

## Phase ledger

Compressed history. The current behaviour of each phase lives
in the architecture map above; CHANGELOG carries the
release-level detail.

| phase | scope |
|---|---|
| 0 | Rigor plugin API spike — locked the `node_rule` + info-diagnostic shape, surfaced the rbs 4.x pin and the `class A::B` owner bug |
| 1 | MVP — `inherits` / `include` / `prepend` / `extend`, DOT / Mermaid, cycle detection, snapshot tests |
| 2 | Zeitwerk inference, `const_ref` (gated on `include_constant_refs`), namespace collapse |
| 3 | `scope.type_of` for indirect mixins — `Singleton[X]` promotes, anything else degrades to `unresolved` |
| 4 | `stats` subcommand, Packwerk overlay (`--package`, `--package-root`), confidence / kind filters |
| 5 | UML class diagram — `nodes.jsonl` (visibility tracked), Rails associations with cardinality, `class-diagram` subcommand |

## Risks worth re-checking

The closed ones (Rigor cache / output-channel race, `class A::B`
owner) live in §"Output channel" and §"Owner resolution" above
with their resolution. Two stay live:

- **The Rigor plugin API is still young.** `rigortype` is pinned
  tight (`~> 0.2.1`); the CI matrix runs against that version
  unchanged. README states the supported range explicitly so a
  future `0.3` bump is a deliberate decision, not a silent break.
- **Ruby constant lookup is not fully reproducible from
  syntax.** The fix is structural, not best-effort: the
  `confidence` ladder lets the consumer choose between recall
  (`unresolved` included) and precision
  (`--confidence syntax,zeitwerk,rigor_type`).
