# Changelog

## Unreleased

- **Contract change: `AshPaper.Fragment.Run` carries the render record's last three fields and
  turns errors into problems.** The fragment now declares `payload_hash_key` (nullable sensitive
  string), `document_version_id` (nullable uuid, no relationship) and `clause_reasons` (array of
  maps, not null, default `[]`), and `record_render` accepts all three. `payload_hash_key` and
  `clause_reasons` may instead ride the action's `context` option
  (`context: %{paper: %{payload_hash_key: key, clause_reasons: reasons}}`,
  `AshPaper.Fragment.FromContext`); an input wins, and only `record_render` takes them, so the key
  is written once. Because the key is now an accepted input, a host that cloaks it beside
  `payload` and `facts` receives it as a sensitive argument and seals it with its own sealer, with
  no extra change. `AshPaper.Fragment.Run.problem/1` maps render, read-back, clause-selection and
  requirement error terms to a JSON-storable map with a `"kind"`; an unknown term is a
  `"render_error"` (or its tuple tag), never a raise. Rendered bytes and digests are unchanged.

  Adopting: a host that declared any of these on its own run resource deletes them when it takes
  this version, or the resource fails to compile with a duplicate attribute:
  - its `payload_hash_key`, `document_version_id` and `clause_reasons` attribute declarations;
  - the change that sealed the key from `context: %{paper: %{payload_hash_key: ...}}` (keep
    `payload_hash_key` in the cloak list and in the sealer's fields), and the change that copied
    `clause_reasons` from the same context. Callers that pass that context keep working unchanged;
  - its own error-to-problem mapping, in favour of `AshPaper.Fragment.Run.problem/1`.

  Declarations equal to the fragment's leave the schema as it is (`mix ash.codegen --check` stays
  clean). A host that lacked a field gets one additive column: a nullable `document_version_id`,
  or `clause_reasons` with default `[]`. No data changes.
- `AshPaper.Compare`: what a change would do to a document already rendered. `compare/3`
  re-renders a recorded render as it was (it must reproduce its recorded digest, bytes or block
  read-back, or the outcome is `:unreproducible`, never `:unchanged`) and as a candidate would
  have it (another layout, theme or clauses, or one clause swapped), and compares the two block by
  block: `:changed` with each block's text and page before and after, `:unchanged`, or `:failed`
  when the candidate does not render or read back. Changes beyond what the candidate was expected
  to touch (other blocks, the page count, the page furniture) are flagged as collateral. A
  baseline that records nothing is refused (`{:error, {:missing_inputs, [:recorded]}}`) unless the
  caller passes `allow_unrecorded: true`, which marks the result `baseline: :unrecorded`.
  `report/3` runs it over many samples under a cap, says when the cap cut them, and counts
  unrecorded cases under their own `unrecorded` count, never as changed or unchanged. Additive.
- `mix paper.impact --layout <module> [--cap N]`: the reviewer's diff for a layout change, over
  the samples a host names with `config :ash_paper, :impact_samples, MyApp.Paper.Samples` (an
  `AshPaper.Compare.Samples`). Fixtures record no digest, so it opts in to unrecorded baselines
  and says so for each sample. Never touches a database; exits non-zero when any sample fails or
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
