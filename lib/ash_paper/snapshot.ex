defmodule AshPaper.Snapshot do
  @moduledoc """
  What produced a document, as an `AshOpenLineage.Snapshot`: hashes and references only.

  The payload hash is keyed, because a hash of a guessable value (an amount, a date) can be
  brute-forced after the value itself has been erased.
  """

  alias AshOpenLineage.Snapshot, as: Value
  alias AshOpenLineage.Snapshot.Definition
  alias AshPaper.{Canonical, Clause, Layout, Payload, Schema, Theme}

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
      definitions: definitions(schema, layout, theme, Keyword.get(opts, :clauses, []), pins),
      payload_hash:
        Canonical.keyed_hash(Keyword.fetch!(opts, :hash_key), Map.from_struct(payload))
    }
    |> Value.put_digest()
  end

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

  defp definition(kind, key, version, hash),
    do: %Definition{
      kind: kind,
      key: to_string(key),
      version: to_string(version),
      content_hash: hash
    }
end
