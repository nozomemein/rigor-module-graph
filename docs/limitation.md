# Known limitations

Current rough edges, indexed by the phase that introduced the
feature. Per-version resolutions land in
[`CHANGELOG.md`](../CHANGELOG.md); the design intent behind each
trade-off lives in [`docs/plan.md`](plan.md).

## Phase 5 — UML class diagram

### Visibility tracker only honours the bare keyword form

`VisibilityMap` flips its running visibility on a bare `private`
/ `protected` / `public` statement inside a class or module body.
Three other Ruby forms fall through and read as `public`:

- `private :foo, :bar` — the explicit symbol form does not move
  the cursor and does not retroactively mark `:foo` / `:bar`.
- `private_class_method` is unrecognised.
- `class << self` blocks are not traced; methods inside them
  surface as public class methods on the surrounding constant.

The bare keyword covers the common Rails-model and plain-module
shapes. Anything more elaborate reads as `public`.

### The bundled inflector is intentionally small

`Rigor::ModuleGraph::Inflector` ships the basic Rails-style
rules (`-ies → -y`, `-s → ""`) plus a small irregular-plurals
table (`people`, `men`, `women`, `children`, `feet`, `teeth`,
`geese`, `mice`, `lice`). Anything outside the table is treated
as regular and acronyms are not recognised:

- `data → datum` and `analyses → analyse` come out wrong.
- `API` / `URL` camelise as `Api` / `Url`.

When the inferred name is wrong, override with `class_name:` —
it always wins over the inflector:

```ruby
has_many :data_points, class_name: "Telemetry::DataPoint"
```

We deliberately do not pull in `ActiveSupport::Inflector`: the
gem stays a standalone Rigor plugin, and the inflections users
actually need on the wrong-by-default path are project-specific
anyway.

### Mermaid 10.x `classDiagram` and the `<<module>>` annotation

Module nodes carry a `«module»` suffix on the label rather than
the canonical UML `<<module>>` annotation. Mermaid 10.x's
`classDiagram` parser silently rejects the document when the
annotation co-exists with the `class Foo["Label"]` form we need
for namespaced constants (`Billing::Invoice` →
`Billing__Invoice` with a label restoring the `::`). Keeping the
label, which carries the actual name, was the higher-value side
of that trade-off.

Mermaid 11 rewrites the `classDiagram` parser; the workaround
becomes unnecessary once the gem's CI matrix moves to it.
