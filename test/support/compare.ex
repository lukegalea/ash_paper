defmodule AshPaper.Test.LetterWithoutClauses do
  @moduledoc false
  use AshPaper.Layout,
    key: :letter,
    version: 2,
    path: Path.expand("letter_without_clauses.typ", __DIR__)
end

defmodule AshPaper.Test.VisitSchema do
  @moduledoc false
  use AshPaper.Schema

  paper do
    key :visit
    version 1
    field :site, :text, label: "Site"
    field :visited_on, :date, label: "Visited on"

    table :checks do
      field :item, :text, label: "Item"
      field :result, :text, label: "Result"
    end
  end
end

defmodule AshPaper.Test.Visits do
  @moduledoc false
  @behaviour AshPaper.Compare.Samples

  alias AshPaper.{Clause, Payload}
  alias AshPaper.Test.{Build, Letter, VisitSchema}

  @limits [max_pages: 20, timeout_ms: 30_000, isolate?: false]

  @greeting %Clause{
    key: "greeting",
    locale: :en,
    version: 1,
    runs: [{:text, "To the team at "}, {:hole, "site"}, {:text, "."}]
  }

  @scope %Clause{
    key: "scope",
    locale: :en,
    version: 1,
    runs: [{:text, "This report covers the checks made on "}, {:hole, "visited_on"}, {:text, "."}]
  }

  @impl true
  def limits, do: @limits

  def clauses, do: [@greeting, @scope]

  def scope, do: @scope

  def payload(site \\ "North yard", rows \\ 3) do
    {:ok, payload} =
      Payload.build(
        VisitSchema,
        %{
          site: site,
          visited_on: ~D[2026-10-14],
          checks: for(i <- 1..rows, do: %{item: "Check #{i}", result: "Passed"})
        },
        title: "Site visit",
        locale: :en
      )

    payload
  end

  @doc "A baseline: the inputs of one render, with what was recorded of it."
  def baseline(payload \\ payload(), record \\ :digest) do
    {:ok, clauses} = Clause.resolve(clauses(), ["greeting", "scope"], payload)
    inputs = %{layout: Letter, theme: Build.theme(), payload: payload, clauses: clauses}

    case record do
      :none ->
        inputs

      kind ->
        {:ok, rendered} =
          AshPaper.Render.render(Letter, inputs.theme, payload, clauses, @limits)

        Map.merge(inputs, recorded(kind, rendered, inputs.theme))
    end
  end

  defp recorded(:digest, rendered, _theme), do: %{digest: rendered.digest}
  defp recorded(:bytes, rendered, _theme), do: %{bytes: rendered.bytes}

  defp recorded(:blocks, rendered, theme) do
    {:ok, blocks} = AshPaper.Verify.blocks(rendered.bytes, rendered.marks, theme)
    %{blocks: blocks}
  end

  @impl true
  def samples do
    [
      Map.put(baseline(payload("North yard"), :none), :id, "north-yard"),
      Map.put(baseline(payload("East gate", 6), :none), :id, "east-gate")
    ]
  end
end
