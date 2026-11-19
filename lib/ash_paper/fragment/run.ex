defmodule AshPaper.Fragment.Run do
  @moduledoc """
  One attempt to produce a document, with two independent status axes. A host instantiates
  this on its own base resource. A read-back that never ran stays `:not_run`, which is visible
  and is not a pass.

  `payload` and `facts` are frozen at render time. The host seals them under its erasure scope.

  ## The render record

  `record_render` freezes what produced the bytes. Beside the snapshot, digest, payload and
  facts it takes three optional fields:

    * `payload_hash_key`: the secret the snapshot's payload hash was keyed with
      (`AshPaper.Snapshot.build/1`'s `hash_key:`, base64). It is `sensitive?` and never part of
      the snapshot. A host that seals `payload` and `facts` (for example with `AshCloak`) lists
      it beside them: because `record_render` accepts it, a cloaked host receives it as a
      sensitive argument and its sealer handles it exactly like `payload` and `facts`.
    * `document_version_id`: the id of the stored bytes, so whatever destroys them can find
      them. A plain uuid with no relationship; a host that wants one declares
      `belongs_to :document_version, MyStore, source_attribute: :document_version_id,
      define_attribute?: false`.
    * `clause_reasons`: why each clause is in the document, one map per selected clause (its
      key and pins, and the reason in its author's words). Defaults to `[]`.

  `payload_hash_key` and `clause_reasons` may be passed as inputs or in the action's `context`
  option, `context: %{paper: %{payload_hash_key: key, clause_reasons: reasons}}`
  (`AshPaper.Fragment.FromContext`); an input wins. Both roads exist only on `record_render`,
  which runs once (the render must still be `:pending`), so the key is written once and no
  later action overwrites it.

  ## Problems

  `problems` stores maps. `problem/1` turns a render, read-back or issue error term into one.
  """

  use Spark.Dsl.Fragment, of: Ash.Resource

  attributes do
    uuid_primary_key :id

    attribute :document_kind, :string, allow_nil?: false, public?: true

    attribute :render_status, :atom,
      allow_nil?: false,
      default: :pending,
      public?: true,
      constraints: [one_of: [:pending, :rendered, :failed]]

    attribute :read_back_status, :atom,
      allow_nil?: false,
      default: :not_run,
      public?: true,
      constraints: [one_of: [:not_run, :passed, :failed, :unmeasured]]

    attribute :snapshot, :map, public?: true
    attribute :output_digest, :string, public?: true, constraints: [match: ~r/\A[0-9a-f]{64}\z/]
    attribute :problems, {:array, :map}, allow_nil?: false, default: [], public?: true
    attribute :payload, :map, sensitive?: true, public?: true
    attribute :facts, :map, sensitive?: true, public?: true

    attribute :payload_hash_key, :string do
      public? true
      sensitive? true

      description """
      The secret the snapshot's payload hash was keyed with, base64. Never in the snapshot;
      sealed by the host beside `payload` and `facts`.
      """
    end

    attribute :document_version_id, :uuid do
      public? true
      description "The stored bytes this run produced; no relationship, see the moduledoc."
    end

    attribute :clause_reasons, {:array, :map} do
      allow_nil? false
      default []
      public? true
      description "Why each clause is in the document: one map per selected clause."
    end
  end

  actions do
    defaults [:read]

    create :start do
      accept [:document_kind]
    end

    update :record_render do
      accept [
        :snapshot,
        :output_digest,
        :payload,
        :facts,
        :payload_hash_key,
        :document_version_id,
        :clause_reasons
      ]

      validate {AshPaper.Fragment.StoredValue, attribute: :render_status, value: :pending}
      validate present([:snapshot, :output_digest, :payload, :facts])
      change {AshPaper.Fragment.FromContext, field: :payload_hash_key}
      change {AshPaper.Fragment.FromContext, field: :clause_reasons}
      change set_attribute(:render_status, :rendered)
    end

    update :record_render_failure do
      accept [:problems]
      validate {AshPaper.Fragment.StoredValue, attribute: :render_status, value: :pending}
      change set_attribute(:render_status, :failed)
    end

    update :record_read_back do
      accept [:read_back_status, :problems]
      validate {AshPaper.Fragment.StoredValue, attribute: :render_status, value: :rendered}
      validate {AshPaper.Fragment.StoredValue, attribute: :read_back_status, value: :not_run}
      validate one_of(:read_back_status, [:passed, :failed, :unmeasured])
    end
  end

  @doc """
  A render, read-back or issue error term as a map `problems` can store: always a `"kind"`,
  with `"key"`, `"where"` and `"detail"` where the term has them. Never raises. A term it does
  not know is still a problem (`"kind"` from a tuple's tag, otherwise `"render_error"`), never
  dropped; a value JSON could not store is kept as its `inspect/1`.

      iex> AshPaper.Fragment.Run.problem({:mismatch, :field, :fee})
      %{"kind" => "mismatch", "where" => "field", "key" => "fee"}

      iex> AshPaper.Fragment.Run.problem(:timeout)
      %{"kind" => "timeout"}

      iex> AshPaper.Fragment.Run.problem("boom")
      %{"kind" => "render_error", "detail" => ~s("boom")}
  """
  @spec problem(term()) :: %{required(String.t()) => term()}
  def problem({kind, where, key}) when kind in [:mismatch, :unmeasured],
    do: %{"kind" => text(kind), "where" => text(where), "key" => text(key)}

  def problem({:missing_decision_input, key, input}),
    do: %{"kind" => "missing_decision_input", "key" => json(key), "detail" => json(input)}

  def problem({:clause_undecided, key}), do: %{"kind" => "clause_undecided", "key" => json(key)}

  def problem({:clause_decision_failed, key, reason}),
    do: %{"kind" => "clause_decision_failed", "key" => json(key), "detail" => inspect(reason)}

  def problem({:clause_reason_missing, key}),
    do: %{"kind" => "clause_reason_missing", "key" => json(key)}

  def problem({:clause_not_pinned, key, locale}),
    do: %{"kind" => "clause_not_pinned", "key" => json(key), "detail" => text(locale)}

  def problem({:binding_stale, selection}),
    do: %{"kind" => "binding_stale", "detail" => "the binding's pins: #{inspect(selection)}"}

  def problem({:unfilled_holes, key, fields}),
    do: %{"kind" => "unfilled_holes", "key" => json(key), "detail" => inspect(fields)}

  def problem({:missing_fact, entry}) when is_map(entry) and not is_struct(entry),
    do: entry |> json() |> Map.put("kind", "missing_fact")

  def problem({:requirement_failed, entry}) when is_map(entry) and not is_struct(entry),
    do: entry |> json() |> Map.put("kind", "requirement_failed")

  def problem({:requirement_undecided, rules} = tuple) when is_list(rules) do
    if List.improper?(rules),
      do: %{"kind" => "requirement_undecided", "detail" => inspect(tuple)},
      else: %{"kind" => "requirement_undecided", "detail" => Enum.map_join(rules, ", ", &text/1)}
  end

  def problem({:requirement_error, detail}),
    do: %{"kind" => "requirement_error", "detail" => json(detail)}

  def problem(atom) when is_atom(atom) and not is_nil(atom), do: %{"kind" => text(atom)}

  def problem(tuple) when is_tuple(tuple) and tuple_size(tuple) > 0,
    do: %{"kind" => text(elem(tuple, 0)), "detail" => inspect(tuple)}

  def problem(other), do: %{"kind" => "render_error", "detail" => inspect(other)}

  # A name as text; a value that is not one is inspected rather than raising.
  defp text(value) when is_binary(value), do: value
  defp text(value) when is_atom(value) or is_number(value), do: to_string(value)
  defp text(value), do: inspect(value)

  # The value as it is when JSON can store it, otherwise its inspect/1. Maps and lists are
  # walked, so one unstorable leaf does not cost the rest.
  defp json(value) when is_binary(value) or is_atom(value) or is_number(value), do: value

  defp json(value) when is_list(value),
    do: if(List.improper?(value), do: inspect(value), else: Enum.map(value, &json/1))

  defp json(value) when is_map(value) and not is_struct(value),
    do: Map.new(value, fn {k, v} -> {json_key(k), json(v)} end)

  defp json(value), do: inspect(value)

  defp json_key(key) when is_binary(key) or is_atom(key), do: key
  defp json_key(key), do: text(key)
end
