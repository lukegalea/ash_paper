defmodule AshPaper.Fonts do
  @moduledoc "The vendored font pack. System fonts are never read, so a render cannot vary with the machine."

  @families ["Carlito", "Caladea", "Liberation Serif", "Liberation Sans"]

  @spec families() :: [String.t()]
  def families, do: @families

  @spec dir() :: String.t()
  def dir, do: Application.app_dir(:ash_paper, "priv/fonts")

  @doc "One hash over every font file's name and contents."
  @spec pin(String.t()) :: String.t()
  def pin(dir \\ dir()) do
    dir
    |> Path.join("*.ttf")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(&{Path.basename(&1), AshPaper.Canonical.sha256(File.read!(&1))})
    |> Map.new()
    |> AshPaper.Canonical.hash()
  end
end
