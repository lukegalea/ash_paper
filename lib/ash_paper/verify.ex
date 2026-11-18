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

  @typedoc """
  One document's labelled blocks, as read back from its bytes.

  Each block is under the id `"<kind>:<key>"` (`"field:vendor"`, `"clause:intro"`,
  `"row:lines/0"`) and holds the page its start mark is on and its text: the runs inside the
  body region from its start mark to its end mark (a table row: to the next mark), a line at a
  time, lines joined by one space. `text` is nil when the block's end cannot be located.
  `order` lists the ids as the document reads. `furniture` is the text outside the body region
  (the page footer), read the same way. Compare two readings with `squash/1`, which is how
  `read_back/5` compares.
  """
  @type blocks :: %{
          pages: non_neg_integer(),
          order: [String.t()],
          blocks: %{
            String.t() => %{
              kind: String.t(),
              key: String.t(),
              page: pos_integer(),
              text: String.t() | nil
            }
          },
          furniture: String.t()
        }

  @kinds ["field", "clause", "row"]

  @spec read_back(binary(), [map()], Payload.t(), [map()], Theme.t()) :: outcome()
  def read_back(bytes, marks, %Payload{} = payload, clauses, %Theme{} = theme) do
    case Text.runs(bytes) do
      {:ok, runs, heights} ->
        {body, _furniture} = split_body(runs, heights, theme)
        texts = for b <- located(body, marks), into: %{}, do: {{b.kind, b.key}, b.text}
        compare(texts, marks, payload, clauses)

      {:error, reason} ->
        %{status: :unmeasured, problems: [{:unreadable, reason}], checked: 0}
    end
  end

  @doc """
  The text of each labelled block of `bytes`, located by `marks` inside `theme`'s body
  region: exactly what `read_back/5` compares against the payload, kept as text so that two
  renders can be compared block by block. A block whose key repeats is read at its first
  start mark, as `read_back/5` reads it. `{:error, reason}` when the bytes cannot be read.
  """
  @spec blocks(binary(), [map()], Theme.t()) :: {:ok, blocks()} | {:error, term()}
  def blocks(bytes, marks, %Theme{} = theme) do
    case Text.runs(bytes) do
      {:ok, runs, heights} ->
        {body, furniture} = split_body(runs, heights, theme)
        found = Enum.map(located(body, marks), &{"#{&1.kind}:#{&1.key}", &1})

        {:ok,
         %{
           pages: map_size(heights),
           order: Enum.map(found, &elem(&1, 0)),
           blocks: Map.new(found),
           furniture: lines(furniture)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Text with every space removed, so two readings of one block compare equal."
  @spec squash(String.t()) :: String.t()
  def squash(text), do: String.replace(text, ~r/[\s\x{A0}]+/u, "")

  defp split_body(runs, heights, theme) do
    Enum.split_with(
      runs,
      &(&1.top >= theme.margin_y - 1 and &1.top <= heights[&1.page] - theme.margin_y + 1)
    )
  end

  # Every block that has a start mark, at its first start mark, in document order.
  defp located(body, marks) do
    indexed = Enum.with_index(marks)

    indexed
    |> Enum.filter(fn {m, _i} ->
      m["value"]["edge"] == "start" and m["value"]["kind"] in @kinds
    end)
    |> Enum.uniq_by(fn {m, _i} -> {m["value"]["kind"], m["value"]["key"]} end)
    |> Enum.map(fn {m, _i} = start ->
      %{
        kind: m["value"]["kind"],
        key: m["value"]["key"],
        page: m["page"],
        text: block_text(start, body, indexed)
      }
    end)
  end

  # A table row runs to the next mark; a field or clause to its own end mark.
  defp block_text({%{"value" => %{"kind" => "row"}}, index} = start, body, indexed) do
    case Enum.find(indexed, fn {_m, i} -> i == index + 1 end) do
      nil -> nil
      next -> collect(body, position(start), position(next), -1)
    end
  end

  defp block_text({%{"value" => %{"kind" => kind, "key" => key}}, _index} = start, body, indexed) do
    case find(indexed, kind, key, "end") do
      nil -> nil
      stop -> collect(body, position(start), position(stop), 0.5)
    end
  end

  defp compare(texts, marks, payload, clauses) do
    indexed = Enum.with_index(marks)

    results =
      Enum.map(payload.field_order, &field(&1, payload, texts)) ++
        Enum.map(clauses, &clause(&1, texts)) ++
        Enum.flat_map(payload.table_order, &table(&1, payload, texts, indexed))

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

  defp field(key, payload, texts) do
    with {:ok, text} <- block("field", key, texts) do
      if String.contains?(text, squash(payload.fields[key])),
        do: :ok,
        else: {:mismatch, :field, key}
    end
  end

  defp clause(%{key: key, text: expected}, texts) do
    with {:ok, text} <- block("clause", key, texts) do
      if text == squash(expected), do: :ok, else: {:mismatch, :clause, key}
    end
  end

  defp table(name, payload, texts, marks) do
    rows = payload.tables[name]
    columns = payload.columns[name]

    found =
      Enum.count(marks, fn {m, _i} ->
        m["value"]["kind"] == "row" and String.starts_with?(m["value"]["key"], name <> "/")
      end)

    if found != length(rows) do
      [{:unmeasured, :table, name}]
    else
      rows |> Enum.with_index() |> Enum.map(&row(&1, name, columns, texts))
    end
  end

  defp row({values, index}, name, columns, texts) do
    key = "#{name}/#{index}"

    with {:ok, text} <- block("row", key, texts) do
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

  defp block(kind, key, texts) do
    case Map.get(texts, {kind, key}) do
      text when is_binary(text) -> {:ok, squash(text)}
      nil -> {:unmeasured, kind, key}
    end
  end

  defp find(marks, kind, key, edge) do
    Enum.find(marks, fn {m, _i} ->
      m["value"]["kind"] == kind and m["value"]["key"] == key and m["value"]["edge"] == edge
    end)
  end

  defp position({mark, _index}), do: {mark["page"], mark["y"]}

  # The runs between two marks, a line at a time: runs on one line join as they were set,
  # lines join with one space.
  defp collect(runs, {first_page, first_y}, {last_page, last_y}, tolerance) do
    runs
    |> Enum.filter(fn run ->
      after_start = run.page > first_page or (run.page == first_page and run.top >= first_y - 3)

      before_end =
        run.page < last_page or (run.page == last_page and run.top <= last_y + tolerance)

      after_start and before_end
    end)
    |> lines()
  end

  defp lines(runs) do
    runs
    |> Enum.chunk_by(&{&1.page, &1.top})
    |> Enum.map_join(" ", fn line -> Enum.map_join(line, "", & &1.text) end)
    |> String.replace(~r/[\s\x{A0}]+/u, " ")
    |> String.trim()
  end
end
