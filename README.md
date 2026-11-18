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
`AshPaper.Verify.blocks/3` returns the text of each block as the read-back reads it, so two renders can be compared
block by block.

## Storing a render and coming back to it

A host stores `Payload.document/2` and the payload's `facts`; `Payload.from_document/3` rebuilds the payload from
them (atom or string keys), and `Payload.document_clauses/1` the clauses. `Snapshot.stored/1` is the snapshot as a
JSON column keeps it, `Snapshot.pinned/2` reads a pin (the theme's, say) back out, and `Snapshot.payload_hash/2`
recomputes the keyed payload hash it embeds. `Clause.from_stored/1` reads a clause stored as JSON.

## Comparing two renders

`AshPaper.Compare.compare/3` re-renders a recorded render as it was and as a candidate would have it (another
layout, theme or clauses, or one clause swapped) and compares the two block by block. The baseline must reproduce
what was recorded of it (its digest, its bytes or its block read-back) or the outcome is `:unreproducible`, never
`:unchanged`. A baseline that records none of them is refused unless the caller passes `allow_unrecorded: true`;
the result is then marked `baseline: :unrecorded`, and `report/3` counts it as `unrecorded`, never as `unchanged`.
A candidate that does not render or read back is `:failed`. A change outside what the candidate was
expected to touch (another block, the page count, the page furniture) is flagged as collateral.

```elixir
AshPaper.Compare.compare(
  %{layout: MyApp.Paper.Letter, theme: theme, payload: payload, clauses: clauses, digest: run.digest},
  [clause: revised_clause],
  max_pages: 20, timeout_ms: 30_000
)
#=> {:ok, %{outcome: :changed, blocks: [%{block: "clause:intro", before: "...", after: "..."}], collateral: []}}
```

`mix paper.impact --layout <module> [--cap N]` runs it over the samples a host names with
`config :ash_paper, :impact_samples, MyApp.Paper.Samples` (an `AshPaper.Compare.Samples`), prints the report, and
exits non-zero when any sample fails: the reviewer's diff for a layout change. Fixture samples record no digest, so
the task compares them with `allow_unrecorded: true` and prints that their baseline was not recorded. It never
touches a database.

## Run fragment and AshPlanning

`AshPaper.Fragment.Run` is a run fragment holding what a render used and produced. `AshPaper.Binding` gives the
selection shape an AshPlanning binding needs, and `AshPaper.Binding.check/4` says whether a stored selection still
pins the schema, layout and theme the code declares.

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
