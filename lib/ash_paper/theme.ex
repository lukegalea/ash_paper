defmodule AshPaper.Theme do
  @moduledoc "How a document looks, as typed tokens. A theme is data and never contains Typst."

  @enforce_keys [
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
  defstruct @enforce_keys

  @type t :: %__MODULE__{}

  @papers ~w(us-letter a4)
  @accent ~r/\A#[0-9a-f]{6}\z/

  @spec new(map()) :: {:ok, t()} | {:error, [{atom(), term()}]}
  def new(%{} = tokens) do
    known = Map.new(@enforce_keys, &{Atom.to_string(&1), &1})

    {keyed, unknown} =
      Enum.split_with(tokens, fn {k, _v} -> Map.has_key?(known, to_string(k)) end)

    fields = Map.new(keyed, fn {k, v} -> {known[to_string(k)], v} end)

    problems =
      Enum.map(unknown, fn {k, _v} -> {:unknown_token, k} end) ++
        for(key <- @enforce_keys, not Map.has_key?(fields, key), do: {:missing_token, key}) ++
        for({key, value} <- fields, not valid?(key, value), do: {:invalid_token, key})

    if problems == [], do: {:ok, struct!(__MODULE__, fields)}, else: {:error, problems}
  end

  defp valid?(:key, value), do: is_binary(value) and value != ""
  defp valid?(:version, value), do: is_integer(value) and value > 0

  defp valid?(font, value) when font in [:body_font, :heading_font],
    do: value in AshPaper.Fonts.families()

  defp valid?(:body_size, value), do: is_number(value) and value >= 8 and value <= 14

  defp valid?(margin, value) when margin in [:margin_x, :margin_y],
    do: is_number(value) and value >= 18 and value <= 144

  defp valid?(:paper, value), do: value in @papers
  defp valid?(:accent, value), do: is_binary(value) and Regex.match?(@accent, value)

  @doc "What Typst reads."
  @spec tokens(t()) :: map()
  def tokens(%__MODULE__{} = theme), do: theme |> Map.from_struct() |> Map.drop([:key, :version])

  @spec hash(t()) :: String.t()
  def hash(%__MODULE__{} = theme), do: AshPaper.Canonical.hash(tokens(theme))
end
