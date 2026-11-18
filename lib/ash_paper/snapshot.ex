defmodule AshPaper.Snapshot do
  @moduledoc """
  What produced a document, as an `AshOpenLineage.Snapshot`: hashes and references only.

  The payload hash is keyed, because a hash of a guessable value (an amount, a date) can be
  brute-forced after the value itself has been erased. `payload_hash/2` is that hash, so a host
  holding the key can recompute it without re-deriving how it is taken.

  `build/1` takes `definitions:`, further pins a host made the document under (a decision, a
  rule set), placed after the ones derived here. `stored/1` is the snapshot as a host keeps it
  (its digest beside its canonical JSON, decoded), and `pinned/2` reads pins back out of that.
  """

  alias AshOpenLineage.Snapshot, as: Value
  alias AshOpenLineage.Snapshot.{CanonicalJSON, Definition}
  alias AshPaper.{Canonical, Clause, Layout, Payload, Schema, Theme}

  @typedoc "A snapshot as a host stores it: the digest beside the decoded canonical JSON."
  @type stored :: %{required(String.t()) => term()}

  @doc """
  The snapshot of one render. Required: `id`, `schema`, `layout`, `theme`, `payload`, `pins`,
  `at`, `authority` and `hash_key`. Optional: `clauses`, `inputs`, `purpose`, `world`, and
  `definitions` (`AshOpenLineage.Snapshot.Definition` structs pinned after the derived ones).
  """
  @spec build(keyword()) :: Value.t()
  def build(opts) do
    schema = Keyword.fetch!(opts, :schema)
    layout = Layout.of(Keyword.fetch!(opts, :layout))
    %Theme{} = theme = Keyword.fetch!(opts, :theme)
    %Payload{} = payload = Keyword.fetch!(opts, :payload)
    pins = Keyword.fetch!(opts, :pins)
    at = Keyword.fetch!(opts, :at)

    %Value{
      id: Keyword.fetch!(opts, :id),
      purpose: Keyword.get(opts, :purpose, :"paper.render"),
      effective_at: at,
      knowledge_cutoff: at,
      world: Keyword.get(opts, :world, :operational),
      authority: Keyword.fetch!(opts, :authority),
      inputs: Keyword.get(opts, :inputs, []),
      definitions:
        definitions(schema, layout, theme, Keyword.get(opts, :clauses, []), pins) ++
          extra_definitions(Keyword.get(opts, :definitions, [])),
      payload_hash: payload_hash(Keyword.fetch!(opts, :hash_key), payload)
    }
    |> Value.put_digest()
  end

  @doc """
  The keyed hash of `payload` that `build/1` records as the snapshot's `payload_hash`. `key` is
  the secret `build/1` was given as `hash_key` (at least 16 bytes).
  """
  @spec payload_hash(binary(), Payload.t()) :: String.t()
  def payload_hash(key, %Payload{} = payload),
    do: Canonical.keyed_hash(key, Map.from_struct(payload))

  @doc """
  The snapshot as a host stores it: `%{"digest" => digest, "snapshot" => map}`, where the map is
  the snapshot's canonical JSON decoded, so it survives a JSON column unchanged.
  """
  @spec stored(Value.t()) :: stored()
  def stored(%Value{} = snapshot) do
    %{
      "digest" => snapshot.digest,
      "snapshot" => snapshot |> CanonicalJSON.encode!() |> Jason.decode!()
    }
  end

  @doc """
  The pins of `kind` (`:theme`, `:layout`, `:clause`, or a host's own) in a stored snapshot
  (`stored/1`), each `%{"kind", "key", "version", "content_hash"}`, in the order they were
  pinned. Anything that is not a stored snapshot pins nothing.
  """
  @spec pinned(stored() | term(), atom() | String.t()) :: [map()]
  def pinned(%{"snapshot" => %{"definitions" => definitions}}, kind) when is_list(definitions) do
    kind = to_string(kind)
    Enum.filter(definitions, &match?(%{"kind" => ^kind}, &1))
  end

  def pinned(_stored, _kind), do: []

  @doc false
  def definitions(schema, layout, theme, clauses, pins) do
    fixed = [
      definition(:schema, Schema.key(schema), Schema.version(schema), Schema.hash(schema)),
      definition(:layout, layout.key, layout.version, layout.hash),
      definition(:theme, theme.key, theme.version, Theme.hash(theme))
    ]

    worded =
      for c <- clauses, do: definition(:clause, "#{c.key}/#{c.locale}", c.version, Clause.hash(c))

    engine = for {key, value} <- Enum.sort(pins), do: definition(:engine, key, "pinned", value)
    fixed ++ worded ++ engine
  end

  defp extra_definitions(definitions) when is_list(definitions) do
    Enum.map(definitions, fn
      %Definition{} = definition ->
        definition

      other ->
        raise ArgumentError,
              "a pinned definition must be a #{inspect(Definition)}, got: #{inspect(other)}"
    end)
  end

  defp definition(kind, key, version, hash),
    do: %Definition{
      kind: kind,
      key: to_string(key),
      version: to_string(version),
      content_hash: hash
    }
end
