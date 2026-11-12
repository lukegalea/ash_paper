defmodule AshPaper.Theme do
  @moduledoc """
  How a document looks, as typed tokens. A theme is data and never contains Typst.

  Required tokens: `key`, `version`, `body_font`, `heading_font`, `body_size` (pt), `margin_x` and
  `margin_y` (pt), `paper` and `accent` (`#rrggbb`).

  Optional tokens carry what a hand-authored theme measures from a real document. Each one is
  absent unless given, and an absent token is left out of `tokens/1`, so a theme that sets none of
  them hashes and renders exactly as it did before they existed.

    * `text_color`, `muted_color` (`#rrggbb`): body text, and the page footer.
    * `heading_size` (pt, 10–32): the level-1 heading (the document title).
    * `line_spacing` (1.0–2.0): baseline-to-baseline distance as a multiple of `body_size`, as a
      PDF measures it (Word's "multiple 1.15" on an 11 pt Calibri body measures about 1.40).
    * `paragraph_spacing` (pt, 0–24): extra distance between paragraphs and blocks, like Word's
      "space after". Requires `line_spacing`, because it is measured from the same baselines.
    * `title_rule` (pt, 0–4): a rule in the accent colour under the title; 0 draws none.
    * `table_stroke` (`#rrggbb`): 0.5 pt table rules in that colour.
    * `table_header_fill`, `table_header_text` (`#rrggbb`): the table header row's fill and text.
  """

  @required [
    :key,
    :version,
    :body_font,
    :heading_font,
    :body_size,
    :margin_x,
    :margin_y,
    :paper,
    :accent
  ]

  @optional [
    :text_color,
    :muted_color,
    :heading_size,
    :line_spacing,
    :paragraph_spacing,
    :title_rule,
    :table_stroke,
    :table_header_fill,
    :table_header_text
  ]

  @enforce_keys @required
  defstruct @required ++ @optional

  @type t :: %__MODULE__{}
  @type problem :: {atom(), term()} | {atom(), term(), term()}

  @papers ~w(us-letter a4)
  @color ~r/\A#[0-9a-f]{6}\z/
  @colors [
    :accent,
    :text_color,
    :muted_color,
    :table_stroke,
    :table_header_fill,
    :table_header_text
  ]

  @spec new(map()) :: {:ok, t()} | {:error, [problem()]}
  def new(%{} = tokens) do
    known = Map.new(@required ++ @optional, &{Atom.to_string(&1), &1})

    {keyed, unknown} =
      Enum.split_with(tokens, fn {k, _v} -> Map.has_key?(known, to_string(k)) end)

    fields =
      keyed
      |> Map.new(fn {k, v} -> {known[to_string(k)], v} end)
      |> Map.reject(fn {k, v} -> k in @optional and is_nil(v) end)

    problems =
      Enum.map(unknown, fn {k, _v} -> {:unknown_token, k} end) ++
        for(key <- @required, not Map.has_key?(fields, key), do: {:missing_token, key}) ++
        for({key, value} <- fields, not valid?(key, value), do: {:invalid_token, key}) ++
        requires(fields)

    if problems == [], do: {:ok, struct!(__MODULE__, fields)}, else: {:error, problems}
  end

  defp requires(%{paragraph_spacing: _} = fields) when not is_map_key(fields, :line_spacing),
    do: [{:requires_token, :paragraph_spacing, :line_spacing}]

  defp requires(_fields), do: []

  defp valid?(:key, value), do: is_binary(value) and value != ""
  defp valid?(:version, value), do: is_integer(value) and value > 0

  defp valid?(font, value) when font in [:body_font, :heading_font],
    do: value in AshPaper.Fonts.families()

  defp valid?(:body_size, value), do: in_range?(value, 8, 14)
  defp valid?(margin, value) when margin in [:margin_x, :margin_y], do: in_range?(value, 18, 144)
  defp valid?(:paper, value), do: value in @papers

  defp valid?(color, value) when color in @colors,
    do: is_binary(value) and Regex.match?(@color, value)

  defp valid?(:heading_size, value), do: in_range?(value, 10, 32)
  defp valid?(:line_spacing, value), do: in_range?(value, 1.0, 2.0)
  defp valid?(:paragraph_spacing, value), do: in_range?(value, 0, 24)
  defp valid?(:title_rule, value), do: in_range?(value, 0, 4)

  defp in_range?(value, low, high), do: is_number(value) and value >= low and value <= high

  @doc "What Typst reads: every token except `key` and `version`, and no absent optional token."
  @spec tokens(t()) :: map()
  def tokens(%__MODULE__{} = theme) do
    theme
    |> Map.from_struct()
    |> Map.drop([:key, :version])
    |> Map.reject(fn {k, v} -> k in @optional and is_nil(v) end)
  end

  @spec hash(t()) :: String.t()
  def hash(%__MODULE__{} = theme), do: AshPaper.Canonical.hash(tokens(theme))
end
