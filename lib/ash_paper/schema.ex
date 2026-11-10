defmodule AshPaper.Schema do
  @moduledoc """
  What a kind of document may state: named read paths, declared by the host and locked.

      defmodule MyApp.Paper.Renewal do
        use AshPaper.Schema

        paper do
          key :renewal
          version 1
          resource MyApp.Contract

          field :vendor, :text, path: [:vendor, :name], label: [en: "Vendor", fr: "Fournisseur"]
          field :fee, :money, label: "Fee"
        end
      end

  Paths are checked against `resource` at compile time. A plain-map source has no resource,
  so its paths are checked when the payload is built.
  """

  use Spark.Dsl, default_extensions: [extensions: [AshPaper.Schema.Dsl]]

  alias AshPaper.Schema.{Field, Table}
  alias Spark.Dsl.Extension

  @spec key(module()) :: atom()
  def key(schema), do: Extension.get_opt(schema, [:paper], :key)

  @spec version(module()) :: pos_integer()
  def version(schema), do: Extension.get_opt(schema, [:paper], :version)

  @spec fields(module()) :: [Field.t()]
  def fields(schema),
    do: schema |> Extension.get_entities([:paper]) |> Enum.filter(&is_struct(&1, Field))

  @spec tables(module()) :: [Table.t()]
  def tables(schema),
    do: schema |> Extension.get_entities([:paper]) |> Enum.filter(&is_struct(&1, Table))

  @doc "A hash of everything the schema declares, for the lock."
  @spec hash(module()) :: String.t()
  def hash(schema) do
    AshPaper.Canonical.hash(%{
      key: key(schema),
      version: version(schema),
      resource: inspect(Extension.get_opt(schema, [:paper], :resource)),
      fields: Enum.map(fields(schema), &field_shape/1),
      tables:
        Enum.map(tables(schema), fn t ->
          %{name: t.name, path: t.path, columns: Enum.map(t.columns, &field_shape/1)}
        end)
    })
  end

  defp field_shape(%Field{} = f),
    do: %{
      name: f.name,
      type: f.type,
      path: f.path,
      currency: f.currency,
      required: f.required?,
      label: label_shape(f.label)
    }

  defp label_shape(label) when is_binary(label), do: label
  defp label_shape(label), do: Map.new(label)
end
