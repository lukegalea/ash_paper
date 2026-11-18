defmodule AshPaper.Compare.Samples do
  @moduledoc """
  The documents `mix paper.impact` compares a layout against, named by
  `config :ash_paper, :impact_samples, MyApp.Paper.Samples`.

  Each sample is a baseline as `AshPaper.Compare.compare/3` takes it (`:layout`, `:theme`,
  `:payload`, `:clauses`, optionally a recorded `:digest`, `:bytes` or `:blocks`), with an `:id`
  the report names it by. Samples are fixtures: synthetic values built in code, never read from
  a database.
  """

  @doc "The samples, in the order the report lists them."
  @callback samples() :: [map()]

  @doc "The render limits to compare them under: at least `max_pages:` and `timeout_ms:`."
  @callback limits() :: keyword()
end
