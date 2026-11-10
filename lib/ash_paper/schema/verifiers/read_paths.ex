defmodule AshPaper.Schema.Verifiers.ReadPaths do
  @moduledoc "Every read path must exist on the declared resource and reach one value."

  use Spark.Dsl.Verifier

  alias AshPaper.Schema.{Field, Table}
  alias Spark.Dsl.Transformer
  alias Spark.Error.DslError

  @impl true
  def verify(dsl) do
    module = Transformer.get_persisted(dsl, :module)
    entities = Transformer.get_entities(dsl, [:paper])
    resource = Transformer.get_option(dsl, [:paper], :resource)

    problems = duplicates(entities) ++ if(resource, do: paths(resource, entities), else: [])

    case problems do
      [] ->
        :ok

      _ ->
        {:error,
         DslError.exception(module: module, path: [:paper], message: Enum.join(problems, "; "))}
    end
  end

  defp duplicates(entities) do
    names = Enum.map(entities, & &1.name)
    for name <- Enum.uniq(names -- Enum.uniq(names)), do: "#{name} is declared twice"
  end

  defp paths(resource, entities) do
    case Code.ensure_compiled(resource) do
      {:module, _} -> Enum.flat_map(entities, &entity(resource, &1))
      {:error, why} -> ["#{inspect(resource)} is not available: #{why}"]
    end
  end

  defp entity(resource, %Field{} = field) do
    value = field_path(resource, field.path || [field.name], field.name)
    currency = if field.currency, do: field_path(resource, field.currency, field.name), else: []
    value ++ currency
  end

  defp entity(resource, %Table{} = table) do
    case walk_to_many(resource, table.path || [table.name]) do
      {:ok, destination} -> Enum.flat_map(table.columns, &entity(destination, &1))
      {:error, message} -> ["#{table.name}: #{message}"]
    end
  end

  defp field_path(resource, path, name) do
    {steps, [last]} = Enum.split(path, -1)

    with {:ok, owner} <- walk_to_one(resource, steps),
         %{} <- Ash.Resource.Info.field(owner, last) do
      []
    else
      nil -> ["#{name}: #{last} is not a field of the path's resource"]
      {:error, message} -> ["#{name}: #{message}"]
    end
  end

  defp walk_to_many(resource, path) do
    {steps, [last]} = Enum.split(path, -1)

    with {:ok, owner} <- walk_to_one(resource, steps) do
      case Ash.Resource.Info.relationship(owner, last) do
        %{cardinality: :many, destination: destination} -> {:ok, destination}
        nil -> {:error, "#{last} is not a relationship"}
        _one -> {:error, "#{last} does not hold many rows"}
      end
    end
  end

  defp walk_to_one(resource, steps) do
    Enum.reduce_while(steps, {:ok, resource}, fn step, {:ok, current} ->
      case Ash.Resource.Info.relationship(current, step) do
        %{cardinality: :one, destination: destination} -> {:cont, {:ok, destination}}
        nil -> {:halt, {:error, "#{step} is not a relationship"}}
        _many -> {:halt, {:error, "#{step} holds many rows and cannot be read through"}}
      end
    end)
  end
end
