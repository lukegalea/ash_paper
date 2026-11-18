# Changelog

## Unreleased

- `AshPaper.Compare`: what a change would do to a document already rendered. `compare/3`
  re-renders a recorded render as it was (it must reproduce its recorded digest, bytes or block
  read-back, or the outcome is `:unreproducible`, never `:unchanged`) and as a candidate would
  have it (another layout, theme or clauses, or one clause swapped), and compares the two block by
  block: `:changed` with each block's text and page before and after, `:unchanged`, or `:failed`
  when the candidate does not render or read back. Changes beyond what the candidate was expected
  to touch (other blocks, the page count, the page furniture) are flagged as collateral.
  `report/3` runs it over many samples under a cap and says when the cap cut them. Additive.
- `mix paper.impact --layout <module> [--cap N]`: the reviewer's diff for a layout change, over
  the samples a host names with `config :ash_paper, :impact_samples, MyApp.Paper.Samples` (an
  `AshPaper.Compare.Samples`). Never touches a database; exits non-zero when any sample fails or
  cannot be reproduced.
- What a host needs to store a render and come back to it, so hosts stop re-deriving it. All
  additive: no existing function's output changes, and existing snapshot digests are unchanged.
  - `AshPaper.Render.Rendered.t()`.
  - `AshPaper.Verify.blocks/3`: the text of each labelled block, as `read_back/5` reads it, and
    `AshPaper.Verify.squash/1`, how it compares. `read_back/5` now reads through it.
  - `AshPaper.Payload.from_document/3`: the payload back from a stored `document/2` (atom or
    string keys), and `AshPaper.Payload.document_clauses/1` for the clauses it carries.
  - `AshPaper.Snapshot.payload_hash/2`, the keyed hash the snapshot embeds; `build/1` takes
    `definitions:` (further pins); `stored/1` and `pinned/2` for the stored form.
  - `AshPaper.Binding.check/4`: whether a stored selection still pins the current schema, layout
    and theme.
  - `AshPaper.Clause.from_stored/1`, `from_stored!/1` and `valid_runs?/1` for clauses stored as
    JSON.
- First public version of the kernel: schema, layout, theme and clause axes, deterministic render, read-back, lock task.
