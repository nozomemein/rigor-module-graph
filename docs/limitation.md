# Known limitations

A list of the rough edges that ship with each release. Most map
to a deliberate scope cut documented in
[`docs/plan.md`](plan.md); the rest are upstream behaviour we
work around. Per-version regressions and resolutions land in
[`CHANGELOG.md`](../CHANGELOG.md).

## Phase 5 — UML class diagram

### Visibility tracker only honours the bare keyword form

`VisibilityMap` flips its running visibility on a bare `private`
/ `protected` / `public` statement inside a class or module body.
The remaining Ruby forms fall through and read as `public`:

- the explicit symbol form: `private :foo, :bar` doesn't move
  the cursor and doesn't retroactively mark `:foo` / `:bar`.
- `private_class_method` is unrecognised.
- `class << self` blocks aren't traced; methods inside them
  appear as public class methods on the surrounding constant.

For day-to-day Ruby (Rails models, plain modules), the bare
keyword covers ~90% of the cases. Anything more elaborate prints
as public.

### The bundled inflector is intentionally small

`Rigor::ModuleGraph::Inflector` ships the basic Rails-style
rules (`-ies → -y`, `-s → ""`, a tiny irregular-plurals table
covering `people`, `men`, `women`, `children`, `feet`, `teeth`,
`geese`, `mice`, `lice`). It does **not** plug into
ActiveSupport's `Inflector`, so:

- Irregular plurals outside the bundled table get singularised
  as if regular: `data → datum` fails, `analyses → analyse`
  fails, etc.
- Project-specific acronyms (`API`, `URL`, …) camelise as
  `Api` / `Url`.

When the inferred name is wrong, prefer the explicit override:

```ruby
has_many :data_points, class_name: "Telemetry::DataPoint"
```

`class_name:` always wins over the inflector, so the resolved
name is exact.

### Mermaid 10.x classDiagram + `<<module>>` annotation

We render every Ruby module as a `class` node with a `«module»`
suffix on the label, not via the canonical UML `<<module>>`
annotation. Background: Mermaid 10.x's `classDiagram` parser
silently rejects the document when the annotation co-exists with
the `class Foo["Label"]` form needed for namespaced constants
(`Billing::Invoice` → `Billing__Invoice` with a label). We need
the label form, so the annotation gets dropped.

This is a drop-in fix once Mermaid stabilises that combination
(probably v11 — the rewritten parser handles annotations
differently).
