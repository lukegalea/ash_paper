defmodule AshPaper.Lock do
  @moduledoc """
  The committed identity of every schema and layout. A changed declaration needs a new version:
  `merge/2` refuses to give a version already locked a different hash. Pure.
  """

  alias AshPaper.{Layout, Schema}

  @type entries :: %{String.t() => %{String.t() => term()}}

  @spec entries(schemas: [module()], layouts: [module()]) :: entries()
  def entries(schemas: schemas, layouts: layouts) do
    Map.merge(
      Map.new(
        schemas,
        &{"schema:#{Schema.key(&1)}",
         %{"version" => Schema.version(&1), "hash" => Schema.hash(&1)}}
      ),
      Map.new(layouts, fn module ->
        layout = Layout.of(module)
        {"layout:#{layout.key}", %{"version" => layout.version, "hash" => layout.hash}}
      end)
    )
  end

  @doc "Read-path errors. A plain `mix compile` only warns about these, so the lock task refuses them."
  @spec path_problems([module()]) :: [String.t()]
  def path_problems(schemas) do
    for schema <- schemas,
        {:error, error} <- [AshPaper.Schema.Verifiers.ReadPaths.verify(schema.spark_dsl_config())],
        do: "#{inspect(schema)}: #{error.message}"
  end

  @spec merge(entries(), entries()) :: {:ok, entries()} | {:error, [String.t()]}
  def merge(previous, actual) do
    rewrites =
      for {name, entry} <- actual,
          old = previous[name],
          old["version"] == entry["version"],
          old["hash"] != entry["hash"],
          do: "#{name} changed but its version is still #{entry["version"]}; bump the version"

    if rewrites == [], do: {:ok, Map.new(actual, &carry(&1, previous))}, else: {:error, rewrites}
  end

  defp carry({name, entry}, previous) do
    old = previous[name]
    history = (old && old["history"]) || %{}

    history =
      if old && old["version"] != entry["version"],
        do: Map.put(history, to_string(old["version"]), old["hash"]),
        else: history

    {name, Map.put(entry, "history", history)}
  end
end
