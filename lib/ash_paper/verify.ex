defmodule AshPaper.Verify do
  @moduledoc """
  Reads the issued bytes back and compares them to the payload, per labelled block.

  A text search alone proves presence, not position: swapped dates would pass it. Page
  furniture is outside the body region and is not compared. The outcome has three values on
  purpose: a check that could not run is `:unmeasured`, never a pass.
  """

  alias AshPaper.{Payload, Theme}
  alias AshPaper.Pdf.Text

  @type outcome :: %{
          status: :passed | :failed | :unmeasured,
          problems: [term()],
          checked: non_neg_integer()
        }

  @spec read_back(binary(), [map()], Payload.t(), [map()], Theme.t()) :: outcome()
  def read_back(bytes, marks, %Payload{} = payload, clauses, %Theme{} = theme) do
    case Text.runs(bytes) do
      {:ok, runs, heights} -> compare(body(runs, heights, theme), marks, payload, clauses)
      {:error, reason} -> %{status: :unmeasured, problems: [{:unreadable, reason}], checked: 0}
    end
  end

  defp body(runs, heights, theme) do
    Enum.filter(
      runs,
      &(&1.top >= theme.margin_y - 1 and &1.top <= heights[&1.page] - theme.margin_y + 1)
    )
  end

  defp compare(runs, marks, payload, clauses) do
    indexed = Enum.with_index(marks)

    results =
      Enum.map(payload.field_order, &field(&1, payload, runs, indexed)) ++
        Enum.map(clauses, &clause(&1, runs, indexed)) ++
        Enum.flat_map(payload.table_order, &table(&1, payload, runs, indexed))

    summarise(results)
  end

  defp summarise([]), do: %{status: :unmeasured, problems: [:nothing_to_check], checked: 0}

  defp summarise(results) do
    problems = Enum.reject(results, &(&1 == :ok))

    status =
      cond do
        Enum.any?(problems, &match?({:unmeasured, _, _}, &1)) -> :unmeasured
        problems != [] -> :failed
        true -> :passed
      end

    %{status: status, problems: problems, checked: length(results)}
  end

  defp field(key, payload, runs, marks) do
    with {:ok, text} <- block("field", key, runs, marks) do
      if String.contains?(text, squash(payload.fields[key])),
        do: :ok,
        else: {:mismatch, :field, key}
    end
  end

  defp clause(%{key: key, text: expected}, runs, marks) do
    with {:ok, text} <- block("clause", key, runs, marks) do
      if text == squash(expected), do: :ok, else: {:mismatch, :clause, key}
    end
  end

  defp table(name, payload, runs, marks) do
    rows = payload.tables[name]
    columns = payload.columns[name]

    found =
      Enum.count(marks, fn {m, _i} ->
        m["value"]["kind"] == "row" and String.starts_with?(m["value"]["key"], name <> "/")
      end)

    if found != length(rows) do
      [{:unmeasured, :table, name}]
    else
      rows |> Enum.with_index() |> Enum.map(&row(&1, name, columns, runs, marks))
    end
  end

  defp row({values, index}, name, columns, runs, marks) do
    key = "#{name}/#{index}"

    with {:ok, text} <- row_text(key, runs, marks) do
      expected = columns |> Enum.map(&squash(values[&1]))
      if in_order?(text, expected), do: :ok, else: {:mismatch, :row, key}
    end
  end

  defp in_order?(text, parts) do
    Enum.reduce_while(parts, text, fn part, rest ->
      case String.split(rest, part, parts: 2) do
        [_before, after_part] -> {:cont, after_part}
        [_no_match] -> {:halt, false}
      end
    end) != false
  end

  defp block(kind, key, runs, marks) do
    start = find(marks, kind, key, "start")
    stop = find(marks, kind, key, "end")

    if start && stop,
      do: {:ok, collect(runs, position(start), position(stop), 0.5)},
      else: {:unmeasured, kind, key}
  end

  defp row_text(key, runs, marks) do
    case find(marks, "row", key, "start") do
      nil ->
        {:unmeasured, "row", key}

      {_mark, index} = start ->
        case Enum.find(marks, fn {_m, i} -> i == index + 1 end) do
          nil -> {:unmeasured, "row", key}
          next -> {:ok, collect(runs, position(start), position(next), -1)}
        end
    end
  end

  defp find(marks, kind, key, edge) do
    Enum.find(marks, fn {m, _i} ->
      m["value"]["kind"] == kind and m["value"]["key"] == key and m["value"]["edge"] == edge
    end)
  end

  defp position({mark, _index}), do: {mark["page"], mark["y"]}

  defp collect(runs, {first_page, first_y}, {last_page, last_y}, tolerance) do
    runs
    |> Enum.filter(fn run ->
      after_start = run.page > first_page or (run.page == first_page and run.top >= first_y - 3)

      before_end =
        run.page < last_page or (run.page == last_page and run.top <= last_y + tolerance)

      after_start and before_end
    end)
    |> Enum.map_join("", & &1.text)
    |> squash()
  end

  defp squash(text), do: String.replace(text, ~r/[\s\x{A0}]+/u, "")
end
