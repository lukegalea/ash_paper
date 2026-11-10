defmodule AshPaper.Pdf.Reader do
  @moduledoc """
  Low-level, dependency-free PDF reading, used by the read-back verification
  (`AshPaper.Pdf.Text`, `AshPaper.Verify`).

  Two layers:

    * **Raw** (`stream_bodies/1`, `inflate/1`): the raw layer. Streams are found
      by their `stream`/`endstream` keywords and Flate is inflated under per-stream and
      total caps.
    * **Objects** (`read/1`, `pages/1`, `stream_data/2`, `tokens/1`): a tokenizer for PDF
      objects and content streams, an object table (plain objects and objects inside
      object streams, the last definition winning), and the page tree.

  The bytes come from a person or from a provider, so every doubt fails closed: an
  encrypted file, a stream that cannot be delimited, a filter other than Flate, a
  predictor, a recursion past the depth limit, an inflate past the cap, or an inline image
  returns `{:error, reason}`, never a partial answer.

  Values: numbers are integers or floats, names are `{:name, "Foo"}`, strings are
  `{:string, binary}`, references `{:ref, n, g}`, arrays lists, dictionaries maps keyed by
  the name text, and a bare keyword `{:kw, "stream"}` (an operator in a content stream).
  """

  @max_input 50 * 1024 * 1024
  @max_stream 8 * 1024 * 1024
  @max_total 32 * 1024 * 1024
  @max_objects 200_000
  @max_depth 16

  @obj ~r/(?<![0-9])(\d+)[ \t\r\n]+(\d+)[ \t\r\n]+obj(?![A-Za-z])/
  @trailer ~r/trailer[ \t\r\n]*<</

  @type doc :: %{objects: %{{integer(), integer()} => {term(), binary() | nil}}, trailer: map()}

  def max_input, do: @max_input
  def max_stream, do: @max_stream
  def max_total, do: @max_total

  # --- raw layer --------------------------------------------------------------

  @doc """
  `[{dictionary_text, stream_data}]` in file order. Throws `:undelimited` when a stream's
  dictionary cannot be found (the caller treats the whole file as unreadable).
  """
  @spec stream_bodies(binary()) :: [{binary(), binary()}]
  def stream_bodies(bytes) do
    size = byte_size(bytes)

    {bodies, _boundary} =
      bytes
      |> :binary.matches(["stream\r\n", "stream\n"])
      |> Enum.reject(fn {at, _len} -> preceded_by_end?(bytes, at) end)
      |> Enum.reduce({[], 0}, fn {at, len}, {acc, boundary} ->
        start = at + len

        if start < boundary do
          {acc, boundary}
        else
          {stop, _} = find_end(bytes, start, size)

          {[{dictionary(bytes, boundary, at), binary_part(bytes, start, stop - start)} | acc],
           stop + 9}
        end
      end)

    Enum.reverse(bodies)
  end

  defp preceded_by_end?(bytes, at), do: at >= 3 and binary_part(bytes, at - 3, 3) == "end"

  defp find_end(bytes, start, size) do
    case :binary.match(bytes, "endstream", scope: {start, size - start}) do
      :nomatch -> {size, 0}
      found -> found
    end
  end

  # The dictionary of the object that owns the stream at `at`: everything after the last
  # `obj` keyword, searched back to the previous stream's end (or the file start) with no
  # size cap.
  defp dictionary(bytes, from, at) do
    from = min(from, at)
    chunk = binary_part(bytes, from, at - from)

    case :binary.matches(chunk, "obj") do
      [] ->
        throw(:undelimited)

      matches ->
        {pos, len} = List.last(matches)
        binary_part(chunk, pos + len, byte_size(chunk) - pos - len)
    end
  end

  @doc "Inflates a Flate stream within the per-stream cap. `{:ok, binary} | :error`."
  @spec inflate(binary()) :: {:ok, binary()} | :error
  def inflate(data) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z)
      drain(z, :zlib.safeInflate(z, data), [], 0)
    rescue
      _ -> :error
    after
      :zlib.close(z)
    end
  end

  defp drain(z, {state, out}, acc, size) when state in [:continue, :finished] do
    size = size + IO.iodata_length(out)

    cond do
      size > @max_stream -> :error
      state == :finished -> {:ok, IO.iodata_to_binary(Enum.reverse([out | acc]))}
      true -> drain(z, :zlib.safeInflate(z, []), [out | acc], size)
    end
  end

  defp drain(_z, _other, _acc, _size), do: :error

  # --- tokenizer ---------------------------------------------------------------

  @ws [0, 9, 10, 12, 13, 32]
  @delims [?(, ?), ?<, ?>, ?[, ?], ?{, ?}, ?/, ?%]

  @doc """
  Every token of a content stream, with bare keywords as `{:op, "BT"}`. `{:error, reason}`
  on a malformed stream or an inline image.
  """
  @spec tokens(binary()) :: {:ok, [term()]} | {:error, atom()}
  def tokens(bytes) when is_binary(bytes) do
    {:ok, tokens(bytes, [])}
  catch
    :malformed -> {:error, :malformed_content}
    :inline_image -> {:error, :inline_image}
  end

  defp tokens(bin, acc) do
    case skip_ws(bin) do
      "" ->
        Enum.reverse(acc)

      rest ->
        {value, rest} = value(rest, false)

        case value do
          {:kw, "BI"} -> throw(:inline_image)
          {:kw, word} -> tokens(rest, [{:op, word} | acc])
          other -> tokens(rest, [other | acc])
        end
    end
  end

  defp skip_ws(<<c, rest::binary>>) when c in @ws, do: skip_ws(rest)

  defp skip_ws(<<?%, rest::binary>>) do
    case :binary.match(rest, ["\n", "\r"]) do
      {at, _} -> skip_ws(binary_part(rest, at, byte_size(rest) - at))
      :nomatch -> ""
    end
  end

  defp skip_ws(bin), do: bin

  # value(bin, refs?) :: {term, rest}; throws :malformed
  defp value(<<"<<", rest::binary>>, refs?), do: dict(rest, refs?, %{})
  defp value(<<"[", rest::binary>>, refs?), do: array(rest, refs?, [])
  defp value(<<"(", rest::binary>>, _refs?), do: literal(rest, 1, [])

  defp value(<<"<", rest::binary>>, _refs?) do
    case :binary.match(rest, ">") do
      {at, _} ->
        hex = binary_part(rest, 0, at)
        tail = binary_part(rest, at + 1, byte_size(rest) - at - 1)
        {{:string, hex_decode(hex)}, tail}

      :nomatch ->
        throw(:malformed)
    end
  end

  defp value(<<"/", rest::binary>>, _refs?) do
    {name, rest} = take_regular(rest)
    {{:name, decode_name(name)}, rest}
  end

  defp value(<<c, _::binary>> = bin, refs?) when c in ?0..?9 or c in [?+, ?-, ?.] do
    {text, rest} = take_regular(bin)
    number = number(text)

    if refs? and is_integer(number) and number >= 0,
      do: maybe_ref(number, rest),
      else: {number, rest}
  end

  defp value(<<c, _::binary>>, _refs?) when c in [?), ?>, ?], ?{, ?}], do: throw(:malformed)

  defp value(bin, _refs?) do
    {word, rest} = take_regular(bin)
    if word == "", do: throw(:malformed)

    case word do
      "true" -> {true, rest}
      "false" -> {false, rest}
      "null" -> {nil, rest}
      _ -> {{:kw, word}, rest}
    end
  end

  defp maybe_ref(n, rest) do
    with <<c, _::binary>> = r1 when c in ?0..?9 <- skip_ws(rest),
         {gtext, r2} = take_regular(r1),
         {g, ""} <- Integer.parse(gtext),
         <<"R", after_r::binary>> <- skip_ws(r2),
         true <- boundary?(after_r) do
      {{:ref, n, g}, after_r}
    else
      _ -> {n, rest}
    end
  end

  defp boundary?(""), do: true
  defp boundary?(<<c, _::binary>>), do: c in @ws or c in @delims

  defp take_regular(bin) do
    len = regular_len(bin, 0)
    {binary_part(bin, 0, len), binary_part(bin, len, byte_size(bin) - len)}
  end

  defp regular_len(bin, i) when i >= byte_size(bin), do: i

  defp regular_len(bin, i) do
    c = :binary.at(bin, i)
    if c in @ws or c in @delims, do: i, else: regular_len(bin, i + 1)
  end

  defp number(text) do
    cond do
      Regex.match?(~r/\A[+-]?\d+\z/, text) ->
        String.to_integer(String.trim_leading(text, "+"))

      Regex.match?(~r/\A[+-]?(\d+\.\d*|\.\d+)\z/, text) ->
        normalised =
          text
          |> String.trim_leading("+")
          |> String.replace(~r/\A(-?)\./, "\\g{1}0.")
          |> then(&if String.ends_with?(&1, "."), do: &1 <> "0", else: &1)

        String.to_float(normalised)

      true ->
        throw(:malformed)
    end
  end

  defp dict(bin, refs?, acc) do
    case skip_ws(bin) do
      <<">>", rest::binary>> ->
        {acc, rest}

      <<"/", _::binary>> = rest ->
        {{:name, key}, rest} = value(rest, refs?)
        {val, rest} = value(skip_ws(rest), refs?)
        dict(rest, refs?, Map.put(acc, key, val))

      _ ->
        throw(:malformed)
    end
  end

  defp array(bin, refs?, acc) do
    case skip_ws(bin) do
      <<"]", rest::binary>> ->
        {Enum.reverse(acc), rest}

      "" ->
        throw(:malformed)

      rest ->
        {val, rest} = value(rest, refs?)
        array(rest, refs?, [val | acc])
    end
  end

  defp literal(<<>>, _depth, _acc), do: throw(:malformed)
  defp literal(<<?\\, c, rest::binary>>, depth, acc), do: escape(c, rest, depth, acc)
  defp literal(<<?(, rest::binary>>, depth, acc), do: literal(rest, depth + 1, [?( | acc])

  defp literal(<<?), rest::binary>>, 1, acc),
    do: {{:string, acc |> Enum.reverse() |> :erlang.list_to_binary()}, rest}

  defp literal(<<?), rest::binary>>, depth, acc), do: literal(rest, depth - 1, [?) | acc])
  defp literal(<<c, rest::binary>>, depth, acc), do: literal(rest, depth, [c | acc])

  @escapes %{?n => ?\n, ?r => ?\r, ?t => ?\t, ?b => ?\b, ?f => ?\f}

  defp escape(c, rest, depth, acc) when is_map_key(@escapes, c),
    do: literal(rest, depth, [Map.fetch!(@escapes, c) | acc])

  defp escape(?\n, rest, depth, acc), do: literal(rest, depth, acc)
  defp escape(?\r, rest, depth, acc), do: literal(skip_lf(rest), depth, acc)
  defp escape(d, rest, depth, acc) when d in ?0..?7, do: octal(<<d, rest::binary>>, depth, acc)
  defp escape(other, rest, depth, acc), do: literal(rest, depth, [other | acc])

  defp skip_lf(<<?\n, rest::binary>>), do: rest
  defp skip_lf(rest), do: rest

  defp octal(bin, depth, acc) do
    digits = bin |> :binary.bin_to_list() |> Enum.take(3) |> Enum.take_while(&(&1 in ?0..?7))
    n = digits |> List.to_string() |> String.to_integer(8)

    literal(binary_part(bin, length(digits), byte_size(bin) - length(digits)), depth, [
      Bitwise.band(n, 255) | acc
    ])
  end

  defp hex_decode(hex) do
    clean = for <<c <- hex>>, c not in @ws, into: "", do: <<c>>
    clean = if rem(byte_size(clean), 2) == 1, do: clean <> "0", else: clean

    case Base.decode16(clean, case: :mixed) do
      {:ok, bin} -> bin
      :error -> throw(:malformed)
    end
  end

  defp decode_name(name) do
    if String.contains?(name, "#") do
      Regex.replace(~r/#([0-9A-Fa-f]{2})/, name, fn _, hex ->
        <<String.to_integer(hex, 16)>>
      end)
    else
      name
    end
  end

  # --- object layer ------------------------------------------------------------

  @doc """
  Reads the object table. `{:ok, doc}` or `{:error, reason}` with reasons `:too_large`,
  `:not_a_pdf`, `:encrypted`, `:malformed`, `:too_many_objects`, `:unreadable_object_stream`.
  """
  @spec read(binary()) :: {:ok, doc()} | {:error, atom()}
  def read(bytes) when is_binary(bytes) do
    cond do
      byte_size(bytes) > @max_input ->
        {:error, :too_large}

      :binary.match(binary_part(bytes, 0, min(byte_size(bytes), 1024)), "%PDF-") == :nomatch ->
        {:error, :not_a_pdf}

      true ->
        do_read(bytes)
    end
  end

  def read(_other), do: {:error, :not_a_pdf}

  defp do_read(bytes) do
    trailer_at = for [{at, len}] <- Regex.scan(@trailer, bytes, return: :index), do: at + len - 2
    {objects, trailers} = scan(bytes, 0, %{}, [], 0, trailer_at)
    trailers = trailers ++ trailers_from_xref_streams(objects)
    objects = expand_object_streams(objects)

    if Enum.any?(trailers, &Map.has_key?(&1, "Encrypt")),
      do: {:error, :encrypted},
      else: {:ok, %{objects: objects, trailer: merge_trailers(trailers, objects)}}
  catch
    :malformed -> {:error, :malformed}
    :too_many_objects -> {:error, :too_many_objects}
    :unreadable_object_stream -> {:error, :unreadable_object_stream}
  end

  defp merge_trailers(trailers, objects) do
    merged = Enum.reduce(trailers, %{}, &Map.merge(&2, &1))

    if Map.has_key?(merged, "Root") do
      merged
    else
      catalog =
        Enum.find_value(objects, fn
          {ref, {%{"Type" => {:name, "Catalog"}}, _}} -> ref
          _ -> nil
        end)

      case catalog do
        {n, g} -> Map.put(merged, "Root", {:ref, n, g})
        nil -> merged
      end
    end
  end

  defp trailers_from_xref_streams(objects) do
    for {_ref, {%{"Type" => {:name, "XRef"}} = dict, _}} <- objects, do: dict
  end

  # Sequential scan: each object is parsed at its keyword and its stream body skipped, so
  # an `obj` pattern inside binary stream data is never mistaken for an object.
  defp scan(bytes, pos, objects, trailers, count, trailer_at) do
    trailer_at = Enum.drop_while(trailer_at, &(&1 < pos))
    next_obj = Regex.run(@obj, bytes, offset: pos, return: :index)
    obj_at = next_obj && next_obj |> hd() |> elem(0)

    cond do
      next_obj == nil and trailer_at == [] ->
        {objects, Enum.reverse(trailers)}

      trailer_at != [] and (obj_at == nil or hd(trailer_at) < obj_at) ->
        [at | rest_at] = trailer_at
        {dict, next} = read_trailer(bytes, at)
        scan(bytes, next, objects, [dict | trailers], count, rest_at)

      true ->
        {entry, next} = read_object(bytes, next_obj, count)

        scan(
          bytes,
          next,
          Map.put(objects, elem(entry, 0), elem(entry, 1)),
          trailers,
          count + 1,
          trailer_at
        )
    end
  end

  defp read_trailer(bytes, at) do
    size = byte_size(bytes)
    {dict, rest} = value(binary_part(bytes, at, size - at), true)
    if not is_map(dict), do: throw(:malformed)
    {dict, size - byte_size(rest)}
  end

  defp read_object(_bytes, _match, count) when count >= @max_objects, do: throw(:too_many_objects)

  defp read_object(bytes, [{at, len}, {ns, nl}, {gs, gl}], _count) do
    size = byte_size(bytes)
    n = bytes |> binary_part(ns, nl) |> String.to_integer()
    g = bytes |> binary_part(gs, gl) |> String.to_integer()
    start = at + len
    {val, after_val} = value(skip_ws(binary_part(bytes, start, size - start)), true)
    {stream, after_stream} = maybe_stream(val, after_val)
    {{{n, g}, {val, stream}}, size - byte_size(after_stream)}
  end

  defp maybe_stream(%{} = dict, rest) do
    case skip_ws(rest) do
      <<"stream", after_kw::binary>> -> stream_data_from(dict, eol(after_kw))
      _ -> {nil, rest}
    end
  end

  defp maybe_stream(_val, rest), do: {nil, rest}

  defp eol(<<"\r\n", rest::binary>>), do: rest
  defp eol(<<"\n", rest::binary>>), do: rest
  defp eol(<<"\r", rest::binary>>), do: rest
  defp eol(rest), do: rest

  defp stream_data_from(dict, body) do
    length = Map.get(dict, "Length")

    if is_integer(length) and length >= 0 and length <= byte_size(body) and
         end_follows?(binary_part(body, length, byte_size(body) - length)) do
      data = binary_part(body, 0, length)
      {data, binary_part(body, length, byte_size(body) - length)}
    else
      case :binary.match(body, "endstream") do
        {at, _} ->
          data = body |> binary_part(0, at) |> trim_eol()
          {data, binary_part(body, at, byte_size(body) - at)}

        :nomatch ->
          throw(:malformed)
      end
    end
  end

  defp end_follows?(rest), do: match?(<<"endstream", _::binary>>, skip_ws(rest))

  defp trim_eol(data) do
    cond do
      String.ends_with?(data, "\r\n") ->
        binary_part(data, 0, byte_size(data) - 2)

      String.ends_with?(data, "\n") or String.ends_with?(data, "\r") ->
        binary_part(data, 0, byte_size(data) - 1)

      true ->
        data
    end
  end

  defp expand_object_streams(objects) do
    streams =
      for {ref, {%{"Type" => {:name, "ObjStm"}} = dict, data}} <- objects,
          is_binary(data),
          do: {ref, dict, data}

    {expanded, _total} =
      Enum.reduce(streams, {objects, 0}, fn {_ref, dict, data}, {acc, total} ->
        decoded =
          case decode(dict, data) do
            {:ok, decoded} -> decoded
            _ -> throw(:unreadable_object_stream)
          end

        if total + byte_size(decoded) > @max_total, do: throw(:unreadable_object_stream)

        {Enum.reduce(object_stream_entries(dict, decoded), acc, fn {n, val}, a ->
           Map.put(a, {n, 0}, {val, nil})
         end), total + byte_size(decoded)}
      end)

    expanded
  end

  defp object_stream_entries(dict, decoded) do
    n = dict["N"]
    first = dict["First"]

    if not (is_integer(n) and is_integer(first) and first <= byte_size(decoded)),
      do: throw(:unreadable_object_stream)

    numbers =
      decoded |> binary_part(0, first) |> then(&Regex.scan(~r/\d+/, &1)) |> List.flatten()

    numbers
    |> Enum.map(&String.to_integer/1)
    |> Enum.chunk_every(2, 2, :discard)
    |> Enum.take(n)
    |> Enum.map(fn [num, off] -> {num, entry_value(decoded, first + off)} end)
  end

  defp entry_value(decoded, start) when start <= byte_size(decoded) do
    {val, _} = value(skip_ws(binary_part(decoded, start, byte_size(decoded) - start)), true)
    val
  end

  defp entry_value(_decoded, _start), do: throw(:unreadable_object_stream)

  @doc "Follows a reference (and a chain of them) to its value."
  @spec resolve(doc(), term()) :: term()
  def resolve(doc, value), do: resolve(doc, value, 0)

  defp resolve(doc, {:ref, n, g}, depth) when depth < 8 do
    case doc.objects do
      %{{^n, ^g} => {val, _}} -> resolve(doc, val, depth + 1)
      _ -> nil
    end
  end

  defp resolve(_doc, {:ref, _, _}, _depth), do: nil
  defp resolve(_doc, value, _depth), do: value

  @doc "The decoded bytes of the stream object a reference (or inline stream) names."
  @spec stream_data(doc(), term()) :: {:ok, binary()} | {:error, atom()}
  def stream_data(doc, {:ref, n, g}) do
    case doc.objects do
      %{{^n, ^g} => {%{} = dict, data}} when is_binary(data) -> decode(dict, data)
      _ -> {:error, :not_a_stream}
    end
  end

  def stream_data(_doc, _other), do: {:error, :not_a_stream}

  @doc "The dictionary of a stream object, resolved."
  def dict_of(doc, ref) do
    case resolve(doc, ref) do
      %{} = dict -> dict
      _ -> nil
    end
  end

  @doc "Decodes a stream's data through its `/Filter` (none, or Flate with no predictor)."
  @spec decode(map(), binary()) :: {:ok, binary()} | {:error, atom()}
  def decode(dict, data) do
    case filters(Map.get(dict, "Filter")) do
      [] ->
        if byte_size(data) > @max_stream, do: {:error, :too_large}, else: {:ok, data}

      [{:name, "FlateDecode"}] ->
        if Map.get(dict, "DecodeParms") not in [nil, []] and predictor?(dict),
          do: {:error, :predictor},
          else: inflated(inflate(data))

      _other ->
        {:error, :unsupported_filter}
    end
  end

  defp inflated({:ok, bin}), do: {:ok, bin}
  defp inflated(:error), do: {:error, :inflate_failed}

  defp filters(nil), do: []
  defp filters({:name, _} = f), do: [f]
  defp filters(list) when is_list(list), do: list
  defp filters(_), do: [:unsupported]

  defp predictor?(dict) do
    case Map.get(dict, "DecodeParms") do
      %{"Predictor" => p} when is_integer(p) and p > 1 -> true
      [%{"Predictor" => p}] when is_integer(p) and p > 1 -> true
      %{} -> false
      [%{}] -> false
      _ -> true
    end
  end

  @doc """
  The pages in order: `%{index, ref, dict, media_box, resources, contents}`, with
  `contents` the list of stream references. `{:error, reason}` when the tree cannot be
  walked.
  """
  @spec pages(doc()) :: {:ok, [map()]} | {:error, atom()}
  def pages(doc) do
    with %{} = catalog <- resolve(doc, doc.trailer["Root"]),
         pages_ref when not is_nil(pages_ref) <- catalog["Pages"] do
      {:ok, pages} = walk(doc, pages_ref, %{media_box: nil, resources: nil}, [], 0, MapSet.new())

      {:ok,
       pages
       |> Enum.reverse()
       |> Enum.with_index()
       |> Enum.map(fn {p, i} -> Map.put(p, :index, i) end)}
    else
      _ -> {:error, :no_page_tree}
    end
  catch
    :bad_tree -> {:error, :no_page_tree}
  end

  defp walk(_doc, _node, _inherit, _acc, depth, _seen) when depth > @max_depth,
    do: throw(:bad_tree)

  defp walk(doc, node, inherit, acc, depth, seen) do
    key = if match?({:ref, _, _}, node), do: node, else: make_ref()
    if MapSet.member?(seen, key), do: throw(:bad_tree)
    seen = MapSet.put(seen, key)

    case resolve(doc, node) do
      %{"Kids" => kids} = dict when is_list(kids) ->
        inherit = inherit(doc, dict, inherit)

        {:ok,
         Enum.reduce(kids, acc, fn kid, a ->
           {:ok, a} = walk(doc, kid, inherit, a, depth + 1, seen)
           a
         end)}

      %{} = dict ->
        inherit = inherit(doc, dict, inherit)

        page = %{
          ref: node,
          dict: dict,
          media_box: inherit.media_box,
          resources: inherit.resources || %{},
          contents: content_refs(doc, dict["Contents"])
        }

        {:ok, [page | acc]}

      _ ->
        throw(:bad_tree)
    end
  end

  defp inherit(doc, dict, inherit) do
    %{
      media_box: media_box(doc, dict["MediaBox"]) || inherit.media_box,
      resources: resolve_resources(doc, dict["Resources"]) || inherit.resources
    }
  end

  defp resolve_resources(doc, value) do
    case resolve(doc, value) do
      %{} = dict -> dict
      _ -> nil
    end
  end

  defp media_box(doc, value) do
    case resolve(doc, value) do
      list when is_list(list) and length(list) == 4 ->
        nums = Enum.map(list, &resolve(doc, &1))
        if Enum.all?(nums, &is_number/1), do: nums, else: nil

      _ ->
        nil
    end
  end

  defp content_refs(_doc, nil), do: []

  defp content_refs(doc, {:ref, _, _} = ref) do
    case resolve(doc, ref) do
      list when is_list(list) -> Enum.filter(list, &match?({:ref, _, _}, &1))
      _ -> [ref]
    end
  end

  defp content_refs(_doc, list) when is_list(list),
    do: Enum.filter(list, &match?({:ref, _, _}, &1))

  defp content_refs(_doc, _), do: []
end
