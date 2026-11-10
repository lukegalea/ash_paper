defmodule AshPaper.Format do
  @moduledoc """
  The text of a value as a person reads it on a document, and its strict inverse.

  This is plain code on purpose. Formatting through locale data would make the output depend
  on which locales happen to be loaded and on the data's version, and a document's bytes are
  a record.

  Money always shows its ISO 4217 code: a bare `$` cannot say whether it means CAD or USD once
  one document set holds both. An amount is never rounded. A currency's minor units are the
  minimum shown, not a cap, so a rate of `0.125` keeps three decimals.

  Separators are no-break spaces (U+00A0), never U+202F, which reads back as NUL from some PDF
  text layers.
  """

  @nbsp <<0xA0::utf8>>
  @months_en ~w(January February March April May June July August September October November December)
  @months_fr ~w(janvier février mars avril mai juin juillet août septembre octobre novembre décembre)

  @en ~r/\A(-?)([A-Z]{3})\x{A0}(\d{1,3}(?:,\d{3})*)(?:\.(\d+))?\z/u
  @fr ~r/\A(-?)(\d{1,3}(?:\x{A0}\d{3})*)(?:,(\d+))?\x{A0}([A-Z]{3})\z/u

  @type locale :: :en | :fr

  @spec money(Money.t(), locale()) :: {:ok, String.t()} | {:error, term()}
  def money(%Money{amount: amount, currency: currency}, locale)
      when is_atom(currency) and locale in [:en, :fr] do
    with {:ok, digits} <- minor_units(currency) do
      {whole, fraction} = parts(amount, digits)
      sign = if Decimal.negative?(amount), do: "-", else: ""
      code = Atom.to_string(currency)
      {:ok, sign <> assemble(locale, code, whole, fraction)}
    end
  end

  def money(_other, _locale), do: {:error, :not_a_currency_amount}

  defp assemble(:en, code, whole, fraction),
    do: code <> @nbsp <> group(whole, ",") <> with_fraction(".", fraction)

  defp assemble(:fr, code, whole, fraction),
    do: group(whole, @nbsp) <> with_fraction(",", fraction) <> @nbsp <> code

  defp with_fraction(_separator, ""), do: ""
  defp with_fraction(separator, fraction), do: separator <> fraction

  defp parts(amount, digits) do
    text = amount |> Decimal.abs() |> Decimal.normalize() |> Decimal.to_string(:normal)

    case String.split(text, ".") do
      [whole, fraction] -> {whole, String.pad_trailing(fraction, digits, "0")}
      [whole] -> {whole, String.duplicate("0", digits)}
    end
  end

  defp group(digits, separator) do
    digits
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.map_join(separator, &Enum.join/1)
    |> String.reverse()
  end

  defp minor_units(currency) do
    case Localize.Currency.currency_for_code(currency, locale: :en) do
      {:ok, %{iso_digits: digits}} when is_integer(digits) -> {:ok, digits}
      _other -> {:error, {:unknown_currency, currency}}
    end
  end

  @doc "The amount and currency that `money/2` wrote as `text`. Anything else is an error."
  @spec parse_money(String.t(), locale()) :: {:ok, Money.t()} | {:error, term()}
  def parse_money(text, :en) when is_binary(text) do
    case Regex.run(@en, text, capture: :all_but_first) do
      [sign, code, whole] -> build(sign, code, whole, "", ",")
      [sign, code, whole, fraction] -> build(sign, code, whole, fraction, ",")
      nil -> {:error, {:unparseable, text}}
    end
  end

  def parse_money(text, :fr) when is_binary(text) do
    case Regex.run(@fr, text, capture: :all_but_first) do
      [sign, whole, fraction, code] -> build(sign, code, whole, fraction, @nbsp)
      nil -> {:error, {:unparseable, text}}
    end
  end

  defp build(sign, code, whole, fraction, separator) do
    digits = String.replace(whole, separator, "")
    number = sign <> digits <> if(fraction == "", do: "", else: "." <> fraction)

    case Money.new(code, Decimal.new(number)) do
      %Money{} = money -> {:ok, money}
      {:error, _} = error -> error
    end
  end

  @spec date(Date.t(), locale()) :: String.t()
  def date(%Date{year: year, month: month, day: day}, :fr) do
    ordinal = if day == 1, do: "1er", else: Integer.to_string(day)
    "#{ordinal} #{Enum.at(@months_fr, month - 1)} #{year}"
  end

  def date(%Date{year: year, month: month, day: day}, :en),
    do: "#{Enum.at(@months_en, month - 1)} #{day}, #{year}"

  @spec integer(integer(), locale()) :: String.t()
  def integer(value, locale) when is_integer(value) and locale in [:en, :fr] do
    sign = if value < 0, do: "-", else: ""
    separator = if locale == :fr, do: @nbsp, else: ","
    sign <> group(Integer.to_string(abs(value)), separator)
  end
end
