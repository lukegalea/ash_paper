defmodule Mix.Tasks.Paper.Impact do
  @shortdoc "Prints what a layout would change in the configured sample documents"
  @moduledoc """
  `mix paper.impact --layout <module> [--cap N]`

  The reviewer's diff for a layout change. Each sample from the module configured as
  `config :ash_paper, :impact_samples, MyApp.Paper.Samples` (an `AshPaper.Compare.Samples`) is
  rendered as it is and with the layout `<module>`, and the two are compared block by block
  (`AshPaper.Compare.report/3`). The report lists each sample's outcome, the blocks that changed
  with their text before and after, and any collateral (page count, page furniture), then the
  counts and whether `--cap` (default #{AshPaper.Compare.default_cap()}) cut the sample.

  Samples are fixtures and usually record no digest, so the task compares them with
  `allow_unrecorded: true`: each such sample is marked as not recorded, and is counted as
  `unrecorded`, never as changed or unchanged. A sample that records its digest, bytes or
  read-back is checked to reproduce it first.

  It never touches a database: it starts only the kernel and its dependencies. It exits
  non-zero when any sample failed (did not render, or did not read back) or could not be
  reproduced.

  Samples usually live with the tests; configure them for the test environment and run
  `MIX_ENV=test mix paper.impact --layout MyApp.Paper.Letter`.
  """

  use Mix.Task

  alias AshPaper.Compare

  @usage "usage: mix paper.impact --layout <module> [--cap N]"

  @impl true
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [layout: :string, cap: :integer])
    if rest != [] or invalid != [], do: Mix.raise(@usage)

    Mix.Task.run("compile")
    Mix.Task.run("app.config")
    {:ok, _started} = Application.ensure_all_started(:ash_paper)

    layout = layout!(opts[:layout])
    samples = samples!()
    cap = opts[:cap] || Compare.default_cap()

    opts = [cap: cap, allow_unrecorded: true] ++ samples.limits()

    case Compare.report(samples.samples(), [layout: layout], opts) do
      {:ok, report} ->
        Mix.shell().info(format(layout, report))
        finish(report)

      {:error, reason} ->
        Mix.raise("paper.impact could not compare: #{inspect(reason)}")
    end
  end

  defp layout!(nil), do: Mix.raise(@usage)

  defp layout!(name) do
    module =
      try do
        Module.safe_concat([name])
      rescue
        ArgumentError -> Mix.raise("no such module: #{name}")
      end

    if Code.ensure_loaded?(module) and function_exported?(module, :__paper_layout__, 0),
      do: module,
      else: Mix.raise("#{name} is not a paper layout (a module using AshPaper.Layout)")
  end

  defp samples! do
    case Application.get_env(:ash_paper, :impact_samples) do
      nil ->
        Mix.raise(
          "no samples: set config :ash_paper, :impact_samples, MyApp.Paper.Samples " <>
            "(an AshPaper.Compare.Samples)"
        )

      module ->
        if Code.ensure_loaded?(module) and function_exported?(module, :samples, 0) and
             function_exported?(module, :limits, 0),
           do: module,
           else: Mix.raise("#{inspect(module)} is not an AshPaper.Compare.Samples")
    end
  end

  defp finish(report) do
    case report.counts.failed + report.counts.unreproducible do
      0 ->
        :ok

      n ->
        Mix.raise(
          "paper.impact: #{n} of #{report.sample.taken} sample(s) did not pass " <>
            "(#{report.counts.failed} failed, #{report.counts.unreproducible} unreproducible)"
        )
    end
  end

  @doc false
  def format(layout, report) do
    layout = AshPaper.Layout.of(layout)

    header = [
      "paper.impact: layout #{layout.key} v#{layout.version} (#{binary_part(layout.hash, 0, 12)})",
      "",
      Enum.flat_map(report.cases, &case_lines/1),
      counts(report)
    ]

    header |> List.flatten() |> Enum.join("\n")
  end

  defp case_lines(result) do
    [
      "#{result.outcome}  #{result.id}#{baseline(result.baseline)}"
      | details(result)
    ] ++ [""]
  end

  defp baseline(:unrecorded), do: "  (baseline not recorded: not checked to reproduce)"
  defp baseline(_reproduced_or_nil), do: ""

  defp details(%{outcome: outcome, reason: reason}) when outcome in [:failed, :unreproducible],
    do: ["  reason: " <> inspect(reason, limit: 20, printable_limit: 500)]

  defp details(result) do
    Enum.flat_map(result.blocks, fn block ->
      [
        "  #{block.block}  page #{block.page_before || "-"} -> #{block.page_after || "-"}",
        "    - #{block.before || "(absent)"}",
        "    + #{block.after || "(absent)"}"
      ]
    end) ++ collateral(result)
  end

  defp collateral(%{collateral: []}), do: []

  defp collateral(%{collateral: ids, pages: pages}) do
    pages = if "pages" in ids, do: " (pages #{pages.before} -> #{pages.after})", else: ""
    ["  collateral: #{Enum.join(ids, ", ")}#{pages}"]
  end

  defp counts(report) do
    tally =
      Enum.map_join(
        ~w(changed unchanged unrecorded unreproducible failed)a,
        ", ",
        &"#{&1} #{report.counts[&1]}"
      )

    sample = report.sample

    unrecorded =
      case Enum.count(report.cases, &(&1.baseline == :unrecorded)) do
        0 ->
          []

        n ->
          [
            "#{n} sample(s) had no recorded baseline: compared without checking that it " <>
              "reproduces, so none is counted as changed or unchanged"
          ]
      end

    [
      tally <> "; #{report.collateral} with collateral"
      | unrecorded
    ] ++
      [
        "#{sample.taken} sample(s) compared (cap #{sample.cap})" <>
          if(sample.truncated, do: "; the cap cut the sample", else: "")
      ]
  end
end
