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

  @doc """
  The clause a host stored: a map with `key`, `locale`, `version` and `runs` (atom or string
  keys, or a struct holding them), each run `%{"kind" => "text" | "hole", "value" => string}` as
  JSON keeps it. A string locale must name an existing atom. `{:error, reason}` names the first
  part that is not a clause's.
  """
  @spec from_stored(map()) :: {:ok, t()} | {:error, {:invalid, atom()}}
  def from_stored(stored) when is_map(stored) do
    with {:ok, key} <- part(stored, :key, &(is_binary(&1) and &1 != "")),
         {:ok, locale} <- stored_locale(part_value(stored, :locale)),
         {:ok, version} <- part(stored, :version, &(is_integer(&1) and &1 > 0)),
         {:ok, runs} <- part(stored, :runs, &valid_runs?/1) do
      {:ok, %__MODULE__{key: key, locale: locale, version: version, runs: Enum.map(runs, &run/1)}}
    end
  end

  @doc "As `from_stored/1`, raising `ArgumentError` on a map that is not a stored clause."
  @spec from_stored!(map()) :: t()
  def from_stored!(stored) do
    case from_stored(stored) do
      {:ok, clause} -> clause
      {:error, reason} -> raise ArgumentError, "not a stored clause (#{inspect(reason)})"
    end
  end

  @doc """
  Whether `runs` is a list of stored runs: each a map whose `kind` is `"text"` or `"hole"` and
  whose `value` is a string, with string or atom keys (and a kind as a string or an atom).
  """
  @spec valid_runs?(term()) :: boolean()
  def valid_runs?(runs) when is_list(runs), do: Enum.all?(runs, &match?({_, _}, run(&1)))
  def valid_runs?(_runs), do: false

  defp run(stored) when is_map(stored) do
    case {run_kind(part_value(stored, :kind)), part_value(stored, :value)} do
      {kind, value} when kind in [:text, :hole] and is_binary(value) -> {kind, value}
      _malformed -> :error
    end
  end

  defp run(_stored), do: :error

  defp run_kind(kind) when kind in [:text, :hole], do: kind
  defp run_kind("text"), do: :text
  defp run_kind("hole"), do: :hole
  defp run_kind(_other), do: nil

  defp part(stored, name, valid?) do
    value = part_value(stored, name)
    if valid?.(value), do: {:ok, value}, else: {:error, {:invalid, name}}
  end

  defp part_value(stored, name) do
    case Map.fetch(stored, name) do
      {:ok, value} -> value
      :error -> Map.get(stored, Atom.to_string(name))
    end
  end

  defp stored_locale(locale) when is_atom(locale) and locale not in [nil, true, false],
    do: {:ok, locale}

  defp stored_locale(locale) when is_binary(locale) do
    case stored_locale(String.to_existing_atom(locale)) do
      {:ok, atom} -> {:ok, atom}
      {:error, _} -> {:error, {:invalid, :locale}}
    end
  rescue
    ArgumentError -> {:error, {:invalid, :locale}}
  end

  defp stored_locale(_locale), do: {:error, {:invalid, :locale}}
end
