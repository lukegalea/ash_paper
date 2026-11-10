defmodule AshPaper.MixProject do
  use Mix.Project

  def project do
    [
      app: :ash_paper,
      version: "0.1.0-dev",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application, do: [extra_applications: [:logger, :crypto]]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ash, "~> 3.37"},
      {:spark, "~> 2.7"},
      {:ash_typst, "== 0.6.1"},
      {:ash_open_lineage,
       github: "lukegalea/ash_open_lineage", ref: "c35de0bccf39cc2c64db89729736344f1d51462b"},
      {:ex_money, "~> 6.2"},
      {:jason, "~> 1.4"},
      {:stream_data, "~> 1.1"}
    ]
  end
end
