defmodule AshPaper.CompareTest do
  @moduledoc """
  A recorded render re-rendered as it was and as a candidate would have it: the baseline
  control, the candidate's own read-back, the block diff and its collateral.
  """
  use ExUnit.Case, async: true

  alias AshPaper.{Clause, Compare, Layout}
  alias AshPaper.Test.{Build, Letter, LetterWithoutClauses, Visits}

  @limits Visits.limits()

  defp revised(text), do: %{Visits.scope() | version: 2, runs: [{:text, text}]}

  defp compare(baseline, candidate, opts \\ []),
    do: Compare.compare(baseline, candidate, @limits ++ opts)

  describe "an unchanged candidate" do
    test "the same layout is unchanged, its recorded digest reproduced" do
      assert {:ok, result} = compare(Visits.baseline(), layout: Letter)

      assert %{
               outcome: :unchanged,
               reason: nil,
               baseline: :reproduced,
               expected: [],
               blocks: [],
               collateral: [],
               pages: %{before: 1, after: 1}
             } = result
    end

    test "a layout compiled from the same source, as a struct, is unchanged" do
      same = Layout.compile!(:letter, 7, Layout.of(Letter).source)
      assert {:ok, %{outcome: :unchanged}} = compare(Visits.baseline(), layout: same)
    end

    test "a baseline recorded by its bytes or its read-back is reproduced too" do
      for record <- [:bytes, :blocks] do
        baseline = Visits.baseline(Visits.payload(), record)

        assert {:ok, %{outcome: :unchanged, baseline: :reproduced}} = compare(baseline, []),
               "recorded by #{record}"
      end
    end

    test "a read-back stored as JSON is the same record" do
      %{blocks: blocks} = baseline = Visits.baseline(Visits.payload(), :blocks)
      stored = blocks |> Jason.encode!() |> Jason.decode!()

      assert {:ok, %{outcome: :unchanged, baseline: :reproduced}} =
               compare(%{baseline | blocks: stored}, [])
    end

    test "a baseline with nothing recorded is compared, and says so" do
      baseline = Visits.baseline(Visits.payload(), :none)
      assert {:ok, %{outcome: :unchanged, baseline: :unrecorded}} = compare(baseline, [])
    end

    test "a theme that only changes colour changes no block" do
      theme = Build.theme("Carlito", "#7a1f1f")

      assert {:ok, %{outcome: :unchanged, expected: []}} =
               compare(Visits.baseline(), theme: theme)
    end
  end

  describe "a swapped clause" do
    test "changes exactly that clause's block, with its text before and after" do
      baseline = Visits.baseline()
      candidate = revised("This report covers every check made on site.")

      assert {:ok, result} = compare(baseline, clause: candidate)

      assert %{
               outcome: :changed,
               baseline: :reproduced,
               expected: ["clause:scope"],
               collateral: [],
               blocks: [
                 %{
                   block: "clause:scope",
                   before: "This report covers the checks made on " <> _date,
                   after: "This report covers every check made on site.",
                   page_before: 1,
                   page_after: 1
                 }
               ]
             } = result
    end

    test "a resolved clause, or a function of the baseline, swaps it the same way" do
      text = "Checks made on site."
      resolved = %{key: "scope", text: text}

      assert {:ok, %{blocks: [%{block: "clause:scope", after: ^text}], collateral: []}} =
               compare(Visits.baseline(), clause: resolved)

      assert {:ok, %{blocks: [%{block: "clause:scope", after: ^text}], collateral: []}} =
               compare(Visits.baseline(), fn inputs ->
                 assert %{layout: Letter, clauses: [_greeting, _scope]} = inputs
                 {:ok, clause: resolved}
               end)
    end

    test "that moves other blocks and the page count flags them as collateral" do
      long = String.duplicate("Every check is listed below with its result. ", 90)
      assert {:ok, result} = compare(Visits.baseline(), clause: revised(String.trim(long)))

      assert result.outcome == :changed
      assert result.pages.after > result.pages.before
      moved = Enum.map(result.blocks, & &1.block)

      assert "clause:scope" in moved
      assert "row:checks/2" in moved
      refute "clause:scope" in result.collateral
      assert "row:checks/2" in result.collateral
      assert "pages" in result.collateral
      assert "furniture" in result.collateral
      refute Enum.any?(result.collateral, &String.starts_with?(&1, "field:"))
    end

    test "collateral follows what the candidate is expected to touch" do
      long = String.duplicate("Every check is listed below with its result. ", 90)
      candidate = [clause: revised(String.trim(long))]

      assert {:ok, %{collateral: ["pages", "furniture"]}} =
               compare(Visits.baseline(), candidate, expect: :all)
    end
  end

  describe "a candidate that could not be issued fails" do
    test "a layout that drops the clauses fails its read-back" do
      assert {:ok, result} = compare(Visits.baseline(), layout: LetterWithoutClauses)

      assert %{outcome: :failed, baseline: :reproduced, blocks: []} = result
      assert {:read_back, :unmeasured, problems} = result.reason
      assert {:unmeasured, "clause", "greeting"} in problems
      assert {:unmeasured, "clause", "scope"} in problems
    end

    test "a clause with a hole the payload cannot fill" do
      unfillable = %{Visits.scope() | runs: [{:text, "Seen by "}, {:hole, "no_such_field"}]}

      assert {:ok, %{outcome: :failed, reason: {:clause_unresolved, _problems}}} =
               compare(Visits.baseline(), clause: unfillable)
    end

    test "a clause the document does not carry" do
      assert {:ok, %{outcome: :failed, reason: {:clause_not_carried, "closing"}}} =
               compare(Visits.baseline(), clause: %{key: "closing", text: "Regards."})
    end

    test "a candidate function that refuses, raises or returns nonsense" do
      baseline = Visits.baseline()

      assert {:ok, %{outcome: :failed, reason: {:candidate, :no_wording}}} =
               compare(baseline, fn _inputs -> {:error, :no_wording} end)

      assert {:ok, %{outcome: :failed, reason: {:candidate, {:raised, "boom"}}}} =
               compare(baseline, fn _inputs -> raise "boom" end)

      assert {:ok, %{outcome: :failed, reason: {:candidate, {:invalid_candidate, [:colour]}}}} =
               compare(baseline, fn _inputs -> [colour: "red"] end)
    end
  end

  describe "a baseline that does not reproduce is never unchanged" do
    test "a tampered recorded digest is unreproducible" do
      baseline = %{Visits.baseline() | digest: String.duplicate("0", 64)}

      assert {:ok, %{outcome: :unreproducible, reason: :digest_differs, baseline: nil}} =
               compare(baseline, layout: Letter)
    end

    test "a recorded read-back that differs is unreproducible, naming the block" do
      %{blocks: blocks} = baseline = Visits.baseline(Visits.payload(), :blocks)
      tampered = put_in(blocks, [:blocks, "field:site", :text], "Site South yard")

      assert {:ok, %{outcome: :unreproducible, reason: {:blocks_differ, ["field:site"]}}} =
               compare(%{baseline | blocks: tampered}, [])
    end

    test "unreproducible wins over a candidate that would fail" do
      baseline = %{Visits.baseline() | digest: String.duplicate("0", 64)}

      assert {:ok, %{outcome: :unreproducible}} =
               compare(baseline, layout: LetterWithoutClauses)
    end
  end

  describe "arguments that cannot be compared are errors, never raises" do
    test "missing inputs are named" do
      assert {:error, {:missing_inputs, [:layout, :theme]}} =
               compare(%{payload: Visits.payload()}, [])

      assert {:error, {:missing_inputs, [:layout, :theme, :payload]}} = compare([], [])
    end

    test "malformed inputs are named" do
      baseline = Visits.baseline(Visits.payload(), :none)

      assert {:error, {:invalid_inputs, [:layout, :clauses]}} =
               compare(%{baseline | layout: String, clauses: [%{key: "x"}]}, [])

      assert {:error, {:invalid_inputs, [:baseline]}} = compare("a render", [])
    end

    test "recorded bytes that are not the recorded digest" do
      baseline = Visits.baseline(Visits.payload(), :bytes)

      assert {:error, {:invalid_inputs, [:bytes]}} =
               compare(Map.put(baseline, :digest, String.duplicate("0", 64)), [])
    end

    test "a malformed candidate, or no render limits" do
      baseline = Visits.baseline(Visits.payload(), :none)

      assert {:error, {:invalid_candidate, [:colour]}} = compare(baseline, colour: "red")
      assert {:error, {:invalid_candidate, [:layout]}} = compare(baseline, layout: :nope)
      assert {:error, {:invalid_candidate, [:candidate]}} = compare(baseline, "a layout")
      assert {:error, :limits_required} = Compare.compare(baseline, [], [])
      assert {:error, {:invalid_inputs, [:expect]}} = compare(baseline, [], expect: :some)
    end
  end

  describe "a report over many samples" do
    test "counts every outcome and says when the cap cut the sample" do
      samples = Visits.samples()

      assert {:ok, report} = Compare.report(samples, [layout: Letter], [cap: 1] ++ @limits)

      assert report.sample == %{taken: 1, cap: 1, truncated: true}
      assert report.counts == %{changed: 0, unchanged: 1, unreproducible: 0, failed: 0}
      assert [%{id: "north-yard", outcome: :unchanged}] = report.cases

      assert {:ok, %{sample: %{taken: 2, truncated: false}}} =
               Compare.report(samples, [layout: Letter], @limits)
    end

    test "a sample that cannot be compared is a failed case, not a crash" do
      samples = [%{id: "broken", payload: Visits.payload()} | Visits.samples()]

      assert {:ok, report} = Compare.report(samples, [layout: LetterWithoutClauses], @limits)

      assert report.counts == %{changed: 0, unchanged: 0, unreproducible: 0, failed: 3}

      assert %{reason: {:invalid_sample, {:missing_inputs, [:layout, :theme]}}} =
               Enum.find(report.cases, &(&1.id == "broken"))
    end

    test "refuses a cap, a candidate or limits it cannot use" do
      assert {:error, {:invalid_inputs, [:cap]}} =
               Compare.report([], [], [cap: 0] ++ @limits)

      assert {:error, {:invalid_candidate, [:colour]}} =
               Compare.report([], [colour: "red"], @limits)

      assert {:error, :limits_required} = Compare.report([], [], [])
      assert {:error, {:invalid_inputs, [:samples]}} = Compare.report(:none, [], @limits)
    end

    test "a clause swap over samples changes that block in each" do
      candidate = [clause: %Clause{revised("Checks made on site.") | version: 3}]
      assert {:ok, report} = Compare.report(Visits.samples(), candidate, @limits)

      assert report.counts.changed == 2
      assert report.collateral == 0
      assert Enum.all?(report.cases, &match?([%{block: "clause:scope"}], &1.blocks))
    end
  end
end
