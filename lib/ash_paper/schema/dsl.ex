defmodule AshPaper.Schema.Dsl do
  @moduledoc false

  @field_schema [
    name: [type: :atom, required: true],
    type: [type: {:one_of, [:text, :money, :date, :integer]}, required: true],
    path: [type: {:list, :atom}, doc: "Read path from the source. Defaults to the field's name."],
    currency: [
      type: {:list, :atom},
      doc: "Read path to the ISO code, when the amount is a bare decimal."
    ],
    label: [type: {:or, [:string, :keyword_list]}, required: true],
    required?: [type: :boolean, default: true]
  ]

  @field %Spark.Dsl.Entity{
    name: :field,
    target: AshPaper.Schema.Field,
    args: [:name, :type],
    schema: @field_schema
  }

  @table %Spark.Dsl.Entity{
    name: :table,
    target: AshPaper.Schema.Table,
    args: [:name],
    schema: [name: [type: :atom, required: true], path: [type: {:list, :atom}]],
    entities: [columns: [@field]]
  }

  @paper %Spark.Dsl.Section{
    name: :paper,
    schema: [
      key: [type: :atom, required: true],
      version: [type: :pos_integer, required: true],
      resource: [
        type: :atom,
        doc: "The Ash resource read paths start from. Omit when the source is a plain map."
      ]
    ],
    entities: [@field, @table]
  }

  use Spark.Dsl.Extension, sections: [@paper], verifiers: [AshPaper.Schema.Verifiers.ReadPaths]
end
