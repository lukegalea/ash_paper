# AshPaper

Deterministic PDF documents from Ash data. Early: the API may change.

```elixir
AshPaper.Render.render(layout, theme, payload, clauses, limits: [...], engine: ..., fonts: dir)
#=> {:ok, %AshPaper.Render.Rendered{bytes: pdf, ...}}
```

The stored bytes are the record. A render is pure given its pins, so the same inputs give the same bytes.

## The axes

- **Schema**: a Spark DSL naming the read paths a document may use (`field`, `table`). Verified against the source resource.
- **Layout**: host-owned Typst source. It is linted and locked by hash.
- **Theme**: typed tokens (fonts, colours, sizes). Never Typst. Optional look tokens (text and muted colours,
  heading size, baseline-to-baseline line spacing, paragraph spacing, a title rule, table rules and header) let
  a theme be hand-authored from measurements of a real document; a theme that sets none of them hashes and lays
  out exactly as before. See `AshPaper.Theme`.
- **Clause**: wording as literal runs plus typed holes, per locale.

## Money

Every amount carries its ISO currency code. Amounts are never rounded, and formatting has a strict inverse, so
what is printed parses back to the value that was given.

## Determinism

Fonts are vendored (`priv/fonts`), system fonts are ignored, the Typst engine version is pinned, and the PDF
`document_id` is derived from the layout, theme, document and pins. Limits are required, and any compiler warning
fails the render.

## Read-back

After rendering, the PDF is read back and each labelled block is checked against the payload. Each block comes
out `:passed`, `:failed` or `:unmeasured`. The reader handles only Type0 fonts and refuses form XObjects.

## Run fragment and AshPlanning

`AshPaper.Fragment.Run` is a run fragment holding what a render used and produced. `AshPaper.Binding` gives the
selection shape an AshPlanning binding needs.

## Locking

`mix paper.lock` writes `priv/paper.lock.json` from `config :ash_paper, schemas: [...], layouts: [...]`;
`mix paper.lock --check` fails when they drift. Spark verifier errors only warn on a plain compile, so hosts
should compile with `--warnings-as-errors` and run `mix paper.lock --check` in CI.

## Install

Pinned by GitHub ref, not published to Hex:

```elixir
{:ash_paper, github: "lukegalea/ash_paper", ref: "<commit sha>"}
```

## Credits

Carlito, Caladea and Liberation 2.x fonts, under the SIL Open Font License 1.1 (see `priv/fonts/*.copyright`).

MIT licensed.
