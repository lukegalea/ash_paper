defmodule AshPaper.Compare do
  @moduledoc """
  What a change would do to a document already rendered: the document re-rendered as it was
  and as a candidate would have it, compared block by block.

  ## The baseline

  The baseline is a recorded render: the inputs that produced it (`:layout`, `:theme`,
  `:payload`, and the resolved `:clauses` it carried, `%{key:, text:}`) and what was recorded
  of its output: its `:digest`, its `:bytes`, or its block read-back (`:blocks`, as
  `AshPaper.Verify.blocks/3` returns it, with atom or string keys). The baseline is rendered
  again first. It must reproduce everything recorded (the digest, the digest of the bytes, the
  text and page of every block), or the outcome is `:unreproducible` and nothing is compared:
  a document that cannot be reproduced is never `:unchanged`, so every `:changed` is the
  candidate's doing. A baseline that records none of them is compared without that control,
  and the result says so (`baseline: :unrecorded`).

  ## The candidate

  A keyword list (or map) of what changes, or a function of the baseline inputs returning one:

    * `layout:` another layout (a module using `AshPaper.Layout`, or a `%AshPaper.Layout{}`);
    * `theme:` another `%AshPaper.Theme{}`;
    * `clauses:` other resolved clauses, in place of the baseline's;
    * `clause:` one clause swapped for the clause of the same key the document carries: an
      `%AshPaper.Clause{}`, resolved against the baseline's payload, or a resolved
      `%{key:, text:}`.

  The candidate must render and pass its own read-back (`AshPaper.Verify.read_back/5`, with
  the candidate's clauses), or the outcome is `:failed` with the reason: a document that could
  not be issued. So is a candidate that cannot be applied to this document (a clause it does
  not carry, a hole the payload cannot fill, a function that returns `{:error, reason}` or
  raises).

  ## The comparison

  Each labelled block is compared by its text (spaces aside) and the page it starts on. The
  outcome is `:changed`, listing each changed block with its text and page before and after,
  or `:unchanged`. Only text and position are compared: a change of colour alone is
  `:unchanged`.

  A change outside what the candidate was expected to touch is collateral, listed by block id,
  with `"pages"` when the page count moved and `"furniture"` when the text outside the body
  region (the page footer) changed. What a candidate is expected to touch is derived unless
  `expect:` says otherwise: a new layout may touch any block; a clause change, the blocks of
  the clauses whose text it changes; a theme, none.

  Nothing raises. Arguments that cannot be compared at all (a missing or malformed input, no
  render limits) are `{:error, reason}` before anything renders.
  """

  alias AshPaper.{Canonical, Clause, Layout, Payload, Render, Theme, Verify}

  @typedoc "What one render needs."
  @type inputs :: %{
          layout: module() | Layout.t(),
          theme: Theme.t(),
          payload: Payload.t(),
          clauses: [%{key: String.t(), text: String.t()}]
        }

  @typedoc "The changes a candidate makes, or a function of the baseline inputs returning them."
  @type candidate ::
          keyword() | map() | (inputs() -> keyword() | map() | {:error, term()})

  @type changed_block :: %{
          block: String.t(),
          before: String.t() | nil,
          after: String.t() | nil,
          page_before: pos_integer() | nil,
          page_after: pos_integer() | nil
        }

  @type outcome :: :changed | :unchanged | :unreproducible | :failed

  @typedoc """
  One comparison. `reason` is set when the outcome is `:unreproducible` or `:failed`.
  `baseline` is `:reproduced` or `:unrecorded` once the baseline control passed, nil when it
  did not. `pages` is the page count before and after, nil when nothing was compared.
  """
  @type result :: %{
          outcome: outcome(),
          reason: term(),
          baseline: :reproduced | :unrecorded | nil,
          expected: :all | [String.t()],
          blocks: [changed_block()],
          collateral: [String.t()],
          pages: %{before: non_neg_integer(), after: non_neg_integer()} | nil
        }

  @typedoc """
  Many comparisons of one candidate: `counts` per outcome (all four always present),
  `collateral` the number of cases with any, `cases` each result with the sample's `id`, and
  `sample` how many were taken under the cap and whether the cap cut them.
  """
  @type report :: %{
          counts: %{outcome() => non_neg_integer()},
          collateral: non_neg_integer(),
          cases: [map()],
          sample: %{taken: non_neg_integer(), cap: pos_integer(), truncated: boolean()}
        }

  @outcomes [:changed, :unchanged, :unreproducible, :failed]
  @required [:layout, :theme, :payload]
  @candidate_keys [:layout, :theme, :clauses, :clause]
  @default_cap 50

  @doc """
  Compares `baseline` with `candidate`. `opts` are the render options
  (`AshPaper.Render.render/5`: `max_pages:` and `timeout_ms:` are required), plus `expect:`,
  the block ids the candidate is expected to touch (or `:all`), when the derived ones will not
  do.

  `{:error, {:missing_inputs, keys}}`, `{:error, {:invalid_inputs, keys}}`,
  `{:error, {:invalid_candidate, keys}}` or `{:error, :limits_required}` when the arguments
  cannot be compared.
  """
  @spec compare(map() | keyword(), candidate(), keyword()) :: {:ok, result()} | {:error, term()}
  def compare(baseline, candidate, opts) do
    {expect, render_opts} = Keyword.pop(opts, :expect)

    with {:ok, inputs, record} <- baseline(baseline),
         :ok <- limits(render_opts),
         {:ok, candidate} <- candidate(candidate),
         :ok <- expect(expect) do
      {:ok, run(inputs, record, candidate, expect, render_opts)}
    end
  end

  @doc """
  Compares each of `samples` (baselines, each optionally with an `:id`) with `candidate`,
  taking at most `cap:` of them (default #{@default_cap}); the report says when the cap cut the
  sample. `opts` are otherwise `compare/3`'s. A sample whose inputs cannot be compared is a
  `:failed` case with the reason `{:invalid_sample, reason}`.

  `{:error, reason}` when the candidate, the limits or the cap cannot be used for any sample.
  """
  @spec report([map() | keyword()], candidate(), keyword()) :: {:ok, report()} | {:error, term()}
  def report(samples, candidate, opts) when is_list(samples) do
    {cap, opts} = Keyword.pop(opts, :cap, @default_cap)
    {expect, render_opts} = Keyword.pop(opts, :expect)

    with :ok <- cap(cap),
         :ok <- limits(render_opts),
         {:ok, _candidate} <- candidate(candidate),
         :ok <- expect(expect) do
      taken = Enum.take(samples, cap)
      cases = taken |> Enum.with_index() |> Enum.map(&measure(&1, candidate, opts))

      {:ok,
       %{
         counts: Enum.reduce(cases, Map.new(@outcomes, &{&1, 0}), &count/2),
         collateral: Enum.count(cases, &(&1.collateral != [])),
         cases: cases,
         sample: %{taken: length(taken), cap: cap, truncated: length(samples) > cap}
       }}
    end
  end

  def report(_samples, _candidate, _opts), do: {:error, {:invalid_inputs, [:samples]}}

  @doc "How many samples `report/3` takes when no cap is given."
  @spec default_cap() :: pos_integer()
  def default_cap, do: @default_cap

  defp measure({sample, index}, candidate, opts) do
    id = sample_id(sample, index)

    case compare(sample, candidate, opts) do
      {:ok, result} -> Map.put(result, :id, id)
      {:error, reason} -> Map.put(blank(:failed, {:invalid_sample, reason}), :id, id)
    end
  end

  defp sample_id(sample, index) when is_map(sample), do: Map.get(sample, :id, index)
  defp sample_id(sample, index) when is_list(sample), do: Keyword.get(sample, :id, index)
  defp sample_id(_sample, index), do: index

  defp count(result, counts), do: Map.update!(counts, result.outcome, &(&1 + 1))

  defp cap(cap) when is_integer(cap) and cap > 0, do: :ok
  defp cap(_cap), do: {:error, {:invalid_inputs, [:cap]}}

  # ── arguments ──────────────────────────────────────────────────────────

  defp baseline(baseline) when is_list(baseline) do
    if Keyword.keyword?(baseline),
      do: baseline(Map.new(baseline)),
      else: {:error, {:invalid_inputs, [:baseline]}}
  end

  defp baseline(baseline) when is_map(baseline) do
    case for key <- @required, is_nil(Map.get(baseline, key)), do: key do
      [] ->
        invalid =
          for {key, valid?} <- [
                layout: &layout?/1,
                theme: &match?(%Theme{}, &1),
                payload: &match?(%Payload{}, &1),
                clauses: &resolved_clauses?/1,
                digest: &(is_nil(&1) or is_binary(&1)),
                bytes: &(is_nil(&1) or is_binary(&1)),
                blocks: &(is_nil(&1) or recorded_blocks?(&1))
              ],
              not valid?.(Map.get(baseline, key, default(key))),
              do: key

        record(baseline, invalid)

      missing ->
        {:error, {:missing_inputs, missing}}
    end
  end

  defp baseline(_baseline), do: {:error, {:invalid_inputs, [:baseline]}}

  defp default(:clauses), do: []
  defp default(_key), do: nil

  defp record(baseline, []) do
    digest = Map.get(baseline, :digest)
    bytes_digest = baseline |> Map.get(:bytes) |> then(&(&1 && Canonical.sha256(&1)))

    if digest && bytes_digest && digest != bytes_digest do
      {:error, {:invalid_inputs, [:bytes]}}
    else
      {:ok, Map.merge(%{clauses: []}, Map.take(baseline, [:layout, :theme, :payload, :clauses])),
       %{digest: digest || bytes_digest, blocks: Map.get(baseline, :blocks)}}
    end
  end

  defp record(_baseline, invalid), do: {:error, {:invalid_inputs, invalid}}

  defp limits(opts) do
    case {Keyword.get(opts, :max_pages), Keyword.get(opts, :timeout_ms)} do
      {pages, timeout}
      when is_integer(pages) and pages > 0 and is_integer(timeout) and timeout > 0 ->
        :ok

      _missing ->
        {:error, :limits_required}
    end
  end

  defp expect(nil), do: :ok
  defp expect(:all), do: :ok

  defp expect(ids) when is_list(ids),
    do: if(Enum.all?(ids, &is_binary/1), do: :ok, else: {:error, {:invalid_inputs, [:expect]}})

  defp expect(_other), do: {:error, {:invalid_inputs, [:expect]}}

  defp candidate(fun) when is_function(fun, 1), do: {:ok, fun}

  defp candidate(changes) when is_list(changes) do
    if Keyword.keyword?(changes),
      do: candidate(Map.new(changes)),
      else: {:error, {:invalid_candidate, [:candidate]}}
  end

  defp candidate(changes) when is_map(changes) do
    unknown = changes |> Map.keys() |> Enum.reject(&(&1 in @candidate_keys))

    invalid =
      for {key, valid?} <- [
            layout: &layout?/1,
            theme: &match?(%Theme{}, &1),
            clauses: &resolved_clauses?/1,
            clause: &(match?(%Clause{}, &1) or resolved_clause?(&1))
          ],
          Map.has_key?(changes, key),
          not valid?.(Map.fetch!(changes, key)),
          do: key

    case unknown ++ invalid do
      [] -> {:ok, changes}
      keys -> {:error, {:invalid_candidate, keys}}
    end
  end

  defp candidate(_other), do: {:error, {:invalid_candidate, [:candidate]}}

  defp layout?(%Layout{}), do: true

  defp layout?(module) when is_atom(module) and not is_nil(module),
    do: Code.ensure_loaded?(module) and function_exported?(module, :__paper_layout__, 0)

  defp layout?(_other), do: false

  defp resolved_clauses?(clauses),
    do: is_list(clauses) and Enum.all?(clauses, &resolved_clause?/1)

  defp resolved_clause?(%{key: key, text: text}), do: is_binary(key) and is_binary(text)
  defp resolved_clause?(_other), do: false

  defp recorded_blocks?(blocks) do
    is_map(blocks) and is_map(part(blocks, :blocks)) and is_list(part(blocks, :order)) and
      is_integer(part(blocks, :pages))
  end

  # ── the comparison ─────────────────────────────────────────────────────

  defp run(inputs, record, candidate, expect, opts) do
    with {:ok, before_render} <- render(inputs, opts, :baseline_render, :unreproducible),
         :ok <- reproduced(before_render, record.digest),
         {:ok, before} <- blocks(before_render, inputs, :unreproducible, :baseline_unreadable),
         :ok <- same_blocks(record.blocks, before),
         baseline = if(record.digest || record.blocks, do: :reproduced, else: :unrecorded),
         {:ok, changed} <- apply_candidate(candidate, inputs, baseline),
         {:ok, after_render} <- render(changed, opts, :render, {:failed, baseline}),
         :ok <- read_back(after_render, changed, baseline),
         {:ok, after_read} <- blocks(after_render, changed, {:failed, baseline}, :unreadable) do
      expected = expect || expected(inputs, changed)
      diff(before, after_read, expected, baseline)
    else
      {:stop, result} -> result
    end
  end

  defp render(inputs, opts, step, outcome) do
    case Render.render(inputs.layout, inputs.theme, inputs.payload, inputs.clauses, opts) do
      {:ok, rendered} -> {:ok, rendered}
      {:error, reason} -> stop(outcome, {step, reason})
    end
  end

  defp reproduced(_rendered, nil), do: :ok
  defp reproduced(%{digest: digest}, digest), do: :ok
  defp reproduced(_rendered, _digest), do: stop(:unreproducible, :digest_differs)

  defp same_blocks(nil, _read), do: :ok

  defp same_blocks(recorded, read) do
    recorded = normalise(recorded)

    case differences(recorded, read) do
      [] -> :ok
      ids -> stop(:unreproducible, {:blocks_differ, ids})
    end
  end

  defp blocks(rendered, inputs, outcome, step) do
    case Verify.blocks(rendered.bytes, rendered.marks, inputs.theme) do
      {:ok, read} -> {:ok, read}
      {:error, reason} -> stop(outcome, {step, reason})
    end
  end

  defp read_back(rendered, inputs, baseline) do
    case Verify.read_back(
           rendered.bytes,
           rendered.marks,
           inputs.payload,
           inputs.clauses,
           inputs.theme
         ) do
      %{status: :passed} ->
        :ok

      %{status: status, problems: problems} ->
        stop({:failed, baseline}, {:read_back, status, problems})
    end
  end

  defp apply_candidate(fun, inputs, baseline) when is_function(fun, 1) do
    case call(fun, inputs) do
      {:error, reason} ->
        stop({:failed, baseline}, {:candidate, reason})

      changes ->
        case candidate(changes) do
          {:ok, changes} when is_map(changes) ->
            apply_candidate(changes, inputs, baseline)

          {:ok, _function} ->
            stop({:failed, baseline}, {:candidate, {:invalid_candidate, [:candidate]}})

          {:error, reason} ->
            stop({:failed, baseline}, {:candidate, reason})
        end
    end
  end

  defp apply_candidate(changes, inputs, baseline) do
    changed = Map.merge(inputs, Map.take(changes, [:layout, :theme, :clauses]))

    case Map.fetch(changes, :clause) do
      :error -> {:ok, changed}
      {:ok, clause} -> swap(changed, clause, baseline)
    end
  end

  defp call(fun, inputs) do
    case fun.(inputs) do
      {:ok, changes} -> changes
      other -> other
    end
  rescue
    error -> {:error, {:raised, Exception.message(error)}}
  catch
    kind, value -> {:error, {kind, value}}
  end

  defp swap(inputs, %Clause{} = clause, baseline) do
    case Clause.resolve([clause], [clause.key], inputs.payload) do
      {:ok, [resolved]} -> swap(inputs, resolved, baseline)
      {:error, problems} -> stop({:failed, baseline}, {:clause_unresolved, problems})
    end
  end

  defp swap(inputs, %{key: key, text: text}, baseline) do
    if Enum.any?(inputs.clauses, &(&1.key == key)) do
      clauses =
        Enum.map(inputs.clauses, &if(&1.key == key, do: %{key: key, text: text}, else: &1))

      {:ok, %{inputs | clauses: clauses}}
    else
      stop({:failed, baseline}, {:clause_not_carried, key})
    end
  end

  # A new layout may touch any block; otherwise only the clauses whose text changed.
  defp expected(before, candidate) do
    if Layout.of(before.layout).hash != Layout.of(candidate.layout).hash do
      :all
    else
      was = Map.new(before.clauses, &{&1.key, &1.text})
      now = Map.new(candidate.clauses, &{&1.key, &1.text})

      (Map.keys(was) ++ Map.keys(now))
      |> Enum.uniq()
      |> Enum.filter(&(Map.get(was, &1) != Map.get(now, &1)))
      |> Enum.sort()
      |> Enum.map(&("clause:" <> &1))
    end
  end

  defp diff(before, after_read, expected, baseline) do
    changed = Enum.flat_map(ids(before, after_read), &changed(&1, before, after_read))

    outside =
      if expected == :all,
        do: [],
        else: for(%{block: id} <- changed, id not in expected, do: id)

    collateral =
      outside ++
        if(before.pages != after_read.pages, do: ["pages"], else: []) ++
        if(squash(before.furniture) != squash(after_read.furniture),
          do: ["furniture"],
          else: []
        )

    %{
      blank(if(changed == [] and collateral == [], do: :unchanged, else: :changed), nil)
      | baseline: baseline,
        expected: expected,
        blocks: changed,
        collateral: collateral,
        pages: %{before: before.pages, after: after_read.pages}
    }
  end

  defp ids(a, b), do: Enum.uniq(a.order ++ b.order)

  defp differences(a, b) do
    ids = for id <- ids(a, b), moved?(a.blocks[id], b.blocks[id]), do: id

    ids ++
      if(a.pages != b.pages, do: ["pages"], else: []) ++
      if(a.furniture && squash(a.furniture) != squash(b.furniture),
        do: ["furniture"],
        else: []
      )
  end

  defp changed(id, before, after_read) do
    b = before.blocks[id]
    a = after_read.blocks[id]

    if moved?(b, a) do
      [
        %{
          block: id,
          before: b && b.text,
          after: a && a.text,
          page_before: b && b.page,
          page_after: a && a.page
        }
      ]
    else
      []
    end
  end

  defp moved?(nil, nil), do: false
  defp moved?(nil, _after), do: true
  defp moved?(_before, nil), do: true
  defp moved?(b, a), do: b.page != a.page or squash(b.text) != squash(a.text)

  defp squash(nil), do: nil
  defp squash(text), do: Verify.squash(text)

  # A recorded read-back, with atom or string keys, in the shape `Verify.blocks/3` returns.
  defp normalise(recorded) do
    blocks =
      for {id, block} <- part(recorded, :blocks),
          into: %{},
          do: {to_string(id), %{page: part(block, :page), text: part(block, :text)}}

    %{
      pages: part(recorded, :pages),
      order: Enum.map(part(recorded, :order), &to_string/1),
      blocks: blocks,
      furniture: part(recorded, :furniture)
    }
  end

  defp part(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp part(_other, _key), do: nil

  defp stop({:failed, baseline}, reason),
    do: {:stop, %{blank(:failed, reason) | baseline: baseline}}

  defp stop(outcome, reason), do: {:stop, blank(outcome, reason)}

  defp blank(outcome, reason) do
    %{
      outcome: outcome,
      reason: reason,
      baseline: nil,
      expected: [],
      blocks: [],
      collateral: [],
      pages: nil
    }
  end
end
