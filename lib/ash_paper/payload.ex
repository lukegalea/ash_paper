defmodule AshPaper.Payload do
  @moduledoc """
  The values of one document, frozen. `fields` and `tables` are display strings, which let it
  be re-rendered. `facts` are the same values typed, which let a later requirement be replayed.
  A required value that is absent is an error naming it, so a caller can ask for it.
  """

  alias AshPaper.{Format, Schema}
  alias AshPaper.Schema.Field

  @enforce_keys [
    :title,
    :locale,
    :schema_key,
    :schema_version,
    :fields,
    :field_order,
    :labels,
    :tables,
    :table_order,
    :columns,
    :facts
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{}
  @type problem :: {:missing | :not_loaded | :no_currency | :wrong_type, String.t()}

  @spec build(module(), map(), keyword()) :: {:ok, t()} | {:error, [problem()]}
  def build(schema, source, opts) do
    locale = Keyword.fetch!(opts, :locale)
    {fields, field_problems} = read_fields(Schema.fields(schema), source, locale, "")
    tables = Enum.map(Schema.tables(schema), &read_table(&1, source, locale))

    case field_problems ++ Enum.flat_map(tables, &elem(&1, 2)) do
      [] -> {:ok, assemble(schema, Keyword.fetch!(opts, :title), locale, fields, tables)}
      problems -> {:error, problems}
    end
  end

  defp assemble(schema, title, locale, fields, tables) do
    field_labels =
      for f <- Schema.fields(schema), into: %{}, do: {name(f), label(f.label, locale)}

    column_labels =
      for t <- Schema.tables(schema),
          c <- t.columns,
          into: %{},
          do: {"#{t.name}.#{c.name}", label(c.label, locale)}

    %__MODULE__{
      title: title,
      locale: locale,
      schema_key: Schema.key(schema),
      schema_version: Schema.version(schema),
      fields: for({key, display, _fact} <- fields, into: %{}, do: {key, display}),
      field_order: Enum.map(fields, &elem(&1, 0)),
      labels: Map.merge(field_labels, column_labels),
      tables:
        for({key, rows, _} <- tables, into: %{}, do: {key, Enum.map(rows, &rows_display/1)}),
      table_order: Enum.map(tables, &elem(&1, 0)),
      columns:
        for(t <- Schema.tables(schema), into: %{}, do: {name(t), Enum.map(t.columns, &name/1)}),
      facts: %{
        "fields" => for({key, _display, fact} <- fields, into: %{}, do: {key, fact}),
        "tables" =>
          for({key, rows, _} <- tables, into: %{}, do: {key, Enum.map(rows, &rows_facts/1)})
      }
    }
  end

  defp rows_display(row), do: for({key, display, _fact} <- row, into: %{}, do: {key, display})
  defp rows_facts(row), do: for({key, _display, fact} <- row, into: %{}, do: {key, fact})

  defp name(%{name: name}), do: Atom.to_string(name)

  defp label(label, _locale) when is_binary(label), do: label
  defp label(label, locale), do: Keyword.fetch!(label, locale)

  defp read_fields(fields, source, locale, prefix) do
    Enum.reduce(fields, {[], []}, fn field, {done, problems} ->
      case read_field(field, source, locale, prefix <> name(field)) do
        {:ok, triple} -> {done ++ [triple], problems}
        :absent -> {done, problems}
        {:error, problem} -> {done, problems ++ [problem]}
      end
    end)
  end

  defp read_field(%Field{} = field, source, locale, reported) do
    case fetch(source, field.path || [field.name]) do
      {:ok, nil} -> if field.required?, do: {:error, {:missing, reported}}, else: :absent
      {:ok, value} -> convert(field, value, source, locale, reported)
      :not_loaded -> {:error, {:not_loaded, reported}}
    end
  end

  defp read_table(table, source, locale) do
    key = name(table)

    case fetch(source, table.path || [table.name]) do
      {:ok, rows} when is_list(rows) ->
        results =
          rows
          |> Enum.with_index()
          |> Enum.map(fn {row, i} -> read_fields(table.columns, row, locale, "#{key}[#{i}].") end)

        {key, Enum.map(results, &elem(&1, 0)), Enum.flat_map(results, &elem(&1, 1))}

      {:ok, nil} ->
        {key, [], [{:missing, key}]}

      {:ok, _other} ->
        {key, [], [{:wrong_type, key}]}

      :not_loaded ->
        {key, [], [{:not_loaded, key}]}
    end
  end

  defp fetch(source, path) do
    Enum.reduce_while(path, {:ok, source}, fn step, {:ok, current} ->
      case current do
        nil -> {:halt, {:ok, nil}}
        %{^step => %Ash.NotLoaded{}} -> {:halt, :not_loaded}
        %{^step => value} -> {:cont, {:ok, value}}
        %{} -> {:halt, {:ok, nil}}
      end
    end)
  end

  defp convert(%Field{type: :text}, value, _source, _locale, reported) do
    if is_binary(value) and String.trim(value) != "",
      do: {:ok, {last(reported), value, value}},
      else: {:error, {:wrong_type, reported}}
  end

  defp convert(%Field{type: :date}, %Date{} = date, _source, locale, reported),
    do: {:ok, {last(reported), Format.date(date, locale), Date.to_iso8601(date)}}

  defp convert(%Field{type: :integer}, value, _source, locale, reported) when is_integer(value),
    do: {:ok, {last(reported), Format.integer(value, locale), value}}

  defp convert(%Field{type: :money} = field, %Decimal{} = amount, source, locale, reported) do
    with {:ok, code} when is_binary(code) or (is_atom(code) and not is_nil(code)) <-
           fetch(source, field.currency || [:__no_currency_path__]),
         %Money{} = money <- Money.new(code, amount) do
      convert(field, money, source, locale, reported)
    else
      _absent_or_invalid -> {:error, {:no_currency, reported}}
    end
  end

  defp convert(%Field{type: :money}, %Money{} = money, _source, locale, reported) do
    case Format.money(money, locale) do
      {:ok, text} ->
        {:ok,
         {last(reported), text,
          %{
            "amount" => Decimal.to_string(money.amount, :normal),
            "currency" => Atom.to_string(money.currency)
          }}}

      {:error, _} ->
        {:error, {:wrong_type, reported}}
    end
  end

  defp convert(_field, _value, _source, _locale, reported), do: {:error, {:wrong_type, reported}}

  defp last(reported), do: reported |> String.split(".") |> List.last()

  @doc "What Typst reads."
  @spec document(t(), [map()]) :: map()
  def document(%__MODULE__{} = payload, clauses) do
    %{
      title: payload.title,
      locale: payload.locale,
      fields: payload.fields,
      field_order: payload.field_order,
      labels: payload.labels,
      tables: payload.tables,
      table_order: payload.table_order,
      columns: payload.columns,
      clauses: clauses
    }
  end
end
