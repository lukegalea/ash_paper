defmodule AshPaper.Clause do
  @moduledoc """
  Wording: literal runs and typed holes, per locale. A hole names a payload field and is filled
  only from it, so a clause cannot state a value the payload does not hold.
  """

  @enforce_keys [:key, :locale, :version, :runs]
  defstruct @enforce_keys

  @type run :: {:text, String.t()} | {:hole, String.t()}
  @type t :: %__MODULE__{key: String.t(), locale: atom(), version: pos_integer(), runs: [run()]}

  @spec hash(t()) :: String.t()
  def hash(%__MODULE__{} = clause),
    do: AshPaper.Canonical.hash(Enum.map(clause.runs, fn {kind, value} -> [kind, value] end))

  @doc """
  The clauses named by `keys`, in the payload's locale, with holes filled. A clause with no
  variant in that locale, or a hole with no value, is an error: nothing is dropped silently.
  """
  @spec resolve([t()], [String.t()], AshPaper.Payload.t()) ::
          {:ok, [%{key: String.t(), text: String.t()}]} | {:error, [term()]}
  def resolve(clauses, keys, %AshPaper.Payload{} = payload) do
    results = Enum.map(keys, &resolve_one(clauses, &1, payload))

    case for {:error, problem} <- results, do: problem do
      [] -> {:ok, for({:ok, resolved} <- results, do: resolved)}
      problems -> {:error, problems}
    end
  end

  defp resolve_one(clauses, key, payload) do
    case Enum.filter(clauses, &(&1.key == key and &1.locale == payload.locale)) do
      [clause] -> fill(clause, payload)
      [] -> {:error, {:missing_locale, key, payload.locale}}
      _many -> {:error, {:ambiguous_clause, key, payload.locale}}
    end
  end

  defp fill(clause, payload) do
    parts =
      Enum.map(clause.runs, fn
        {:text, text} -> text
        {:hole, field} -> Map.get(payload.fields, field)
      end)

    missing =
      for {:hole, field} <- clause.runs,
          not is_binary(Map.get(payload.fields, field)) or payload.fields[field] == "",
          do: field

    if missing == [],
      do: {:ok, %{key: clause.key, text: Enum.join(parts)}},
      else: {:error, {:unfilled_holes, clause.key, missing}}
  end
end
