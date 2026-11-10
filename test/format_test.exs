defmodule AshPaper.FormatTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias AshPaper.Format

  @narrow_nbsp <<0x202F::utf8>>

  defp amounts do
    gen all(
          whole <- integer(-99_999_999..99_999_999),
          frac <- integer(0..9999),
          digits <- member_of([0, 2, 3, 4])
        ) do
      scale = Integer.pow(10, digits)

      Decimal.add(
        Decimal.new(whole),
        Decimal.div(Decimal.new(rem(frac, scale)), Decimal.new(scale))
      )
    end
  end

  property "every formatted amount parses back to the same amount and currency" do
    check all(
            amount <- amounts(),
            currency <- member_of([:CAD, :USD, :EUR, :GBP, :JPY, :KWD, :CHF]),
            locale <- member_of([:en, :fr]),
            max_runs: 2000
          ) do
      money = Money.new!(currency, amount)
      {:ok, text} = Format.money(money, locale)
      refute String.contains?(text, @narrow_nbsp)
      assert String.contains?(text, Atom.to_string(currency))
      {:ok, back} = Format.parse_money(text, locale)
      assert back.currency == currency, "currency lost in #{inspect(text)}"

      assert Decimal.equal?(back.amount, amount),
             "#{inspect(text)} read back as #{back.amount}, wanted #{amount}"
    end
  end

  test "shows each currency's own minor units and never rounds" do
    assert {:ok, "CAD 4,575.50"} = Format.money(Money.new!(:CAD, "4575.5"), :en)
    assert {:ok, "4 575,50 CAD"} = Format.money(Money.new!(:CAD, "4575.5"), :fr)
    assert {:ok, "USD 4,575.50"} = Format.money(Money.new!(:USD, "4575.5"), :en)
    assert {:ok, "JPY 4,575"} = Format.money(Money.new!(:JPY, "4575"), :en)
    assert {:ok, "4 575,125 KWD"} = Format.money(Money.new!(:KWD, "4575.125"), :fr)
    assert {:ok, "CAD 0.125"} = Format.money(Money.new!(:CAD, "0.125"), :en)
    assert {:ok, "-EUR 1,000.00"} = Format.money(Money.new!(:EUR, "-1000"), :en)
  end

  test "refuses what is not an amount in a currency" do
    assert {:error, _} = Format.money(12, :en)
    assert {:error, _} = Format.parse_money("$4,575.50", :en)
    assert {:error, _} = Format.parse_money("CAD 4,575.50", :fr)
  end

  test "dates and integers in both locales" do
    assert Format.date(~D[2026-12-01], :en) == "December 1, 2026"
    assert Format.date(~D[2026-12-01], :fr) == "1er décembre 2026"
    assert Format.integer(1_234_567, :fr) == "1 234 567"
    assert Format.integer(-1234, :en) == "-1,234"
  end
end
