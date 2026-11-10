defmodule Mix.Tasks.Paper.Lock do
  @shortdoc "Writes or checks the lock of schemas and layouts"
  @moduledoc "`mix paper.lock [--check]`. Modules come from `config :ash_paper, schemas: [...], layouts: [...]`."

  use Mix.Task

  @file_path "priv/paper.lock.json"

  @impl true
  def run(args) do
    Mix.Task.run("compile")

    case AshPaper.Lock.path_problems(configured(:schemas)) do
      [] -> :ok
      problems -> Mix.raise(Enum.join(problems, "\n"))
    end

    actual = AshPaper.Lock.entries(schemas: configured(:schemas), layouts: configured(:layouts))
    previous = read()

    case AshPaper.Lock.merge(previous, actual) do
      {:error, problems} -> Mix.raise(Enum.join(problems, "\n"))
      {:ok, merged} -> finish(merged, previous, "--check" in args)
    end
  end

  defp configured(key), do: Application.get_env(:ash_paper, key, [])

  defp read do
    case File.read(@file_path) do
      {:ok, json} -> Jason.decode!(json)
      {:error, :enoent} -> %{}
    end
  end

  defp finish(merged, previous, true) do
    if merged != previous, do: Mix.raise("#{@file_path} is out of date; run mix paper.lock")
  end

  defp finish(merged, _previous, false) do
    File.write!(@file_path, AshPaper.Canonical.encode(merged) <> "\n")
  end
end
