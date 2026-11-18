defmodule AshPaper.Binding do
  @moduledoc """
  What a paper is bound to, in the shape `AshPlanning.Fragment.Binding` stores. A host
  instantiates that fragment as one temporal row per (tenant, document kind), so what a tenant's
  paper was on any date is a single read. This module only builds the values.
  """

  alias AshPaper.{Canonical, Layout, Schema, Theme}

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

  @doc """
  Whether a stored `selection` still pins what the code declares, and the theme it pins.

  The selection's theme pin must resolve through `theme_by_key` (a function of the pinned key,
  or a map from key to theme) to a theme whose hash is the pinned one, and the selection must
  pin `schema` and `layout` at their current keys and hashes. Anything else is
  `{:error, {:binding_stale, selection}}`, carrying the whole selection, so a document is never
  rendered against a guess and a rebinding decides what renders next. Clause pins are not
  checked here.
  """
  @spec check(
          [map()] | term(),
          module(),
          module() | Layout.t(),
          (String.t() -> Theme.t() | nil) | %{optional(String.t()) => Theme.t()}
        ) :: {:ok, Theme.t()} | {:error, {:binding_stale, term()}}
  def check(selection, schema, layout, theme_by_key) do
    layout = Layout.of(layout)

    current = [
      {"schema", to_string(Schema.key(schema)), Schema.hash(schema)},
      {"layout", to_string(layout.key), layout.hash}
    ]

    with true <- is_list(selection),
         %{"key" => key, "content_hash" => hash} <-
           Enum.find(selection, &match?(%{"kind" => "theme"}, &1)),
         %Theme{} = theme <- lookup(theme_by_key, key),
         true <- Theme.hash(theme) == hash,
         true <- Enum.all?(current, &pinned?(&1, selection)) do
      {:ok, theme}
    else
      _stale -> {:error, {:binding_stale, selection}}
    end
  end

  defp lookup(theme_by_key, key) when is_function(theme_by_key, 1), do: theme_by_key.(key)
  defp lookup(theme_by_key, key) when is_map(theme_by_key), do: Map.get(theme_by_key, key)

  defp pinned?({kind, key, hash}, selection) do
    Enum.any?(selection, fn entry ->
      match?(%{"kind" => ^kind, "key" => ^key, "content_hash" => ^hash}, entry)
    end)
  end

  @doc "One hash of the engine and fonts a binding was reviewed against."
  @spec backend_profile_hash(map()) :: String.t()
  def backend_profile_hash(pins), do: Canonical.hash(pins)
end
