defmodule AshPaper.Pdf.Text do
  @moduledoc """
  Text runs from a Typst PDF: composite (Type0, Identity-H) fonts with a two-byte `/ToUnicode`.

  It fails closed. A font it cannot decode, a code the CMap does not map, a text operator it
  does not implement, or a form XObject (which could hold text it would not see) is an error,
  never missing text.
  """

  alias AshPaper.Pdf.Reader

  @identity {1, 0, 0, 1, 0, 0}
  @unimplemented ~w(' " T* TD TL)

  @type run :: %{page: pos_integer(), top: float(), x: float(), text: String.t()}

  @spec runs(binary()) :: {:ok, [run()], %{pos_integer() => number()}} | {:error, term()}
  def runs(bytes) do
    with {:ok, doc} <- Reader.read(bytes),
         {:ok, pages} <- Reader.pages(doc) do
      numbered = Enum.with_index(pages, 1)
      heights = Map.new(numbered, fn {page, n} -> {n, height(page)} end)
      {:ok, Enum.flat_map(numbered, &page_runs(doc, &1, heights)), heights}
    end
  catch
    {:unreadable, why} -> {:error, {:unreadable, why}}
  end

  @doc "The decoded content streams of every page, in order."
  @spec page_streams(binary()) :: {:ok, [binary()]} | {:error, term()}
  def page_streams(bytes) do
    with {:ok, doc} <- Reader.read(bytes),
         {:ok, pages} <- Reader.pages(doc) do
      {:ok, for(page <- pages, ref <- page.contents, do: stream!(doc, ref))}
    end
  catch
    {:unreadable, why} -> {:error, {:unreadable, why}}
  end

  defp height(%{media_box: [_, _, _, top]}), do: top

  defp stream!(doc, ref) do
    case Reader.stream_data(doc, ref) do
      {:ok, data} -> data
      {:error, reason} -> throw({:unreadable, reason})
    end
  end

  defp page_runs(doc, {page, number}, heights) do
    context = %{doc: doc, fonts: fonts(doc, page), xobjects: xobjects(doc, page)}

    start = %{
      ctm: @identity,
      tm: @identity,
      tlm: @identity,
      stack: [],
      font: nil,
      size: 0,
      ops: [],
      runs: []
    }

    page.contents
    |> Enum.reduce(start, fn ref, state -> interpret(stream!(doc, ref), state, context) end)
    |> Map.fetch!(:runs)
    |> Enum.reverse()
    |> Enum.map(&%{page: number, x: &1.x, top: heights[number] - &1.y, text: &1.text})
  end

  defp interpret(stream, state, context) do
    case Reader.tokens(stream) do
      {:ok, tokens} -> Enum.reduce(tokens, state, &step(&1, &2, context))
      {:error, reason} -> throw({:unreadable, reason})
    end
  end

  defp fonts(doc, page) do
    case Reader.resolve(doc, page.resources["Font"]) do
      %{} = fonts -> Map.new(fonts, fn {name, ref} -> {name, decoder(doc, name, ref)} end)
      _none -> %{}
    end
  end

  defp decoder(doc, name, ref) do
    case Reader.resolve(doc, ref) do
      %{"Subtype" => {:name, "Type0"}, "ToUnicode" => to_unicode} ->
        doc |> stream!(to_unicode) |> cmap() |> nonempty(name)

      _other ->
        throw({:unreadable, {:unsupported_font, name}})
    end
  end

  defp nonempty(map, name) when map_size(map) == 0, do: throw({:unreadable, {:empty_cmap, name}})
  defp nonempty(map, _name), do: map

  defp xobjects(doc, page) do
    case Reader.resolve(doc, page.resources["XObject"]) do
      %{} = xobjects -> xobjects
      _none -> %{}
    end
  end

  @doc false
  def cmap(source) do
    chars =
      for [_, block] <- Regex.scan(~r/beginbfchar(.*?)endbfchar/s, source),
          [_, code, target] <- Regex.scan(~r/<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>/, block),
          into: %{},
          do: {String.to_integer(code, 16), utf16(target)}

    ranges =
      for [_, block] <- Regex.scan(~r/beginbfrange(.*?)endbfrange/s, source),
          [_, low, high, target] <-
            Regex.scan(
              ~r/<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>\s*(<[0-9A-Fa-f]+>|\[[^\]]*\])/,
              block
            ),
          pair <- range(String.to_integer(low, 16), String.to_integer(high, 16), target),
          into: %{},
          do: pair

    Map.merge(chars, ranges)
  end

  defp range(low, high, "[" <> _ = targets) do
    mapped = for [_, hex] <- Regex.scan(~r/<([0-9A-Fa-f]+)>/, targets), do: utf16(hex)
    Enum.zip(low..high//1, mapped)
  end

  defp range(low, high, "<" <> _ = target) do
    hex = target |> String.trim_leading("<") |> String.trim_trailing(">")
    bytes = Base.decode16!(hex, case: :mixed)
    prefix = binary_part(bytes, 0, byte_size(bytes) - 2)
    <<last::16>> = binary_part(bytes, byte_size(bytes) - 2, 2)
    for code <- low..high//1, do: {code, text(<<prefix::binary, last + code - low::16>>)}
  end

  defp utf16(hex), do: hex |> Base.decode16!(case: :mixed) |> text()

  defp text(bytes) do
    case :unicode.characters_to_binary(bytes, {:utf16, :big}, :utf8) do
      value when is_binary(value) -> value
      _invalid -> throw({:unreadable, :invalid_cmap_target})
    end
  end

  defp step({:op, op}, state, context),
    do: exec(op, Enum.reverse(state.ops), %{state | ops: []}, context)

  defp step(operand, state, _context), do: %{state | ops: [operand | state.ops]}

  defp exec(op, _args, _state, _context) when op in @unimplemented,
    do: throw({:unreadable, {:unimplemented_operator, op}})

  defp exec("q", _args, state, _context),
    do: %{state | stack: [{state.ctm, state.font, state.size} | state.stack]}

  defp exec("Q", _args, %{stack: [{ctm, font, size} | rest]} = state, _context),
    do: %{state | ctm: ctm, font: font, size: size, stack: rest}

  defp exec("cm", matrix, state, _context),
    do: %{state | ctm: concat(List.to_tuple(matrix), state.ctm)}

  defp exec("BT", _args, state, _context), do: %{state | tm: @identity, tlm: @identity}
  defp exec("Tf", [{:name, font}, size], state, _context), do: %{state | font: font, size: size}

  defp exec("Tm", matrix, state, _context) do
    tuple = List.to_tuple(matrix)
    %{state | tm: tuple, tlm: tuple}
  end

  defp exec("Td", [x, y], state, _context) do
    moved = concat({1, 0, 0, 1, x, y}, state.tlm)
    %{state | tm: moved, tlm: moved}
  end

  defp exec("Tj", [{:string, bytes}], state, context), do: show(state, bytes, context)

  defp exec("TJ", [list], state, context) when is_list(list),
    do: show(state, for({:string, part} <- list, into: "", do: part), context)

  defp exec("Do", [{:name, name}], state, context) do
    case Reader.dict_of(context.doc, context.xobjects[name]) do
      %{"Subtype" => {:name, "Image"}} -> state
      _other -> throw({:unreadable, {:form_xobject, name}})
    end
  end

  defp exec(_other, _args, state, _context), do: state

  defp show(_state, bytes, _context) when rem(byte_size(bytes), 2) != 0,
    do: throw({:unreadable, :odd_length_string})

  defp show(state, bytes, context) do
    cmap = Map.get(context.fonts, state.font) || throw({:unreadable, {:unknown_font, state.font}})

    text =
      for <<code::16 <- bytes>>, into: "" do
        Map.get(cmap, code) || throw({:unreadable, {:unmapped_code, code}})
      end

    {_a, _b, _c, _d, x, y} = concat(state.tm, state.ctm)
    %{state | runs: [%{x: x, y: y, text: text} | state.runs]}
  end

  defp concat({a1, b1, c1, d1, e1, f1}, {a2, b2, c2, d2, e2, f2}) do
    {a1 * a2 + b1 * c2, a1 * b2 + b1 * d2, c1 * a2 + d1 * c2, c1 * b2 + d1 * d2,
     e1 * a2 + f1 * c2 + e2, e1 * b2 + f1 * d2 + f2}
  end
end
