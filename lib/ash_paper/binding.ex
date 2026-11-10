defmodule AshPaper.Binding do
  @moduledoc """
  What a paper is bound to, in the shape `AshPlanning.Fragment.Binding` stores. A host
  instantiates that fragment as one temporal row per (tenant, document kind), so what a tenant's
  paper was on any date is a single read. This module only builds the values.
  """

  alias AshPaper.Canonical

  @spec selection(module(), module() | AshPaper.Layout.t(), AshPaper.Theme.t(), [
          AshPaper.Clause.t()
        ]) :: [map()]
  def selection(schema, layout, theme, clauses) do
    AshPaper.Snapshot.definitions(schema, AshPaper.Layout.of(layout), theme, clauses, %{})
    |> Enum.map(
      &%{
        "kind" => to_string(&1.kind),
        "key" => &1.key,
        "version" => &1.version,
        "content_hash" => &1.content_hash
      }
    )
    |> Enum.sort_by(&{&1["kind"], &1["key"], &1["version"]})
  end

  @doc "One hash of the engine and fonts a binding was reviewed against."
  @spec backend_profile_hash(map()) :: String.t()
  def backend_profile_hash(pins), do: Canonical.hash(pins)
end
