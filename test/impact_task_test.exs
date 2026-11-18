defmodule Mix.Tasks.Paper.ImpactTest do
  # async: false — the task reads the samples module from the :ash_paper application env,
  # which every test here sets and clears.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Paper.Impact

  setup do
    previous = Application.fetch_env(:ash_paper, :impact_samples)
    Application.put_env(:ash_paper, :impact_samples, AshPaper.Test.Visits)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:ash_paper, :impact_samples, value)
        :error -> Application.delete_env(:ash_paper, :impact_samples)
      end
    end)
  end

  defp run(args), do: capture_io(fn -> Impact.run(args) end)

  test "the samples' own layout changes nothing, and the task passes" do
    output = run(["--layout", "AshPaper.Test.Letter"])

    assert output =~ "paper.impact: layout letter v1"
    assert output =~ "unchanged  north-yard  (baseline not recorded: not checked to reproduce)"
    assert output =~ "unchanged  east-gate  (baseline not recorded"

    assert output =~
             "changed 0, unchanged 0, unrecorded 2, unreproducible 0, failed 0; 0 with collateral"

    assert output =~ "2 sample(s) had no recorded baseline"
    assert output =~ "2 sample(s) compared (cap 50)"
  end

  test "a layout that drops the clauses fails every sample, and the task exits non-zero" do
    output =
      capture_io(fn ->
        assert_raise Mix.Error, ~r/2 of 2 sample\(s\) did not pass \(2 failed/, fn ->
          Impact.run(["--layout", "AshPaper.Test.LetterWithoutClauses"])
        end
      end)

    assert output =~ "failed  north-yard"
    assert output =~ "reason: {:read_back, :unmeasured"
  end

  test "the cap is said when it cuts the sample" do
    output = run(["--layout", "AshPaper.Test.Letter", "--cap", "1"])

    assert output =~ "1 sample(s) compared (cap 1); the cap cut the sample"
    refute output =~ "east-gate"
  end

  test "refuses what it cannot run" do
    assert_raise Mix.Error, ~r/usage/, fn -> Impact.run([]) end
    assert_raise Mix.Error, ~r/usage/, fn -> Impact.run(["--layout", "X", "--colour"]) end

    assert_raise Mix.Error, ~r/no such module/, fn ->
      Impact.run(["--layout", "No.Such.Paper"])
    end

    assert_raise Mix.Error, ~r/not a paper layout/, fn -> Impact.run(["--layout", "String"]) end

    assert_raise Mix.Error, ~r/could not compare/, fn ->
      Impact.run(["--layout", "AshPaper.Test.Letter", "--cap", "0"])
    end

    Application.delete_env(:ash_paper, :impact_samples)

    assert_raise Mix.Error, ~r/no samples/, fn ->
      Impact.run(["--layout", "AshPaper.Test.Letter"])
    end
  end
end
