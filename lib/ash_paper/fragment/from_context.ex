defmodule AshPaper.Fragment.FromContext do
  @moduledoc """
  Takes one `record_render` input from the action's `context` option,
  `context: %{paper: %{field => value}}`, when the caller did not pass it as an input.

      run
      |> Ash.Changeset.for_update(:record_render, inputs,
        context: %{paper: %{payload_hash_key: Base.encode64(key), clause_reasons: reasons}}
      )

  Pass the context as the `context:` option of `for_update/4`: the action's changes run inside
  `for_update`, so context set on the returned changeset arrives too late.

  The value lands where the input would have: the attribute on a plain host; the action's
  argument on a host whose `AshCloak` turned the accepted attribute into one, where the
  host's own sealer (or `AshCloak`'s encrypt) finds it exactly as if it had been passed. A
  host's global changes run after this action change, so a sealer declared there sees it.
  """

  use Ash.Resource.Change

  @impl true
  def init(opts) do
    if is_atom(opts[:field]) and not is_nil(opts[:field]),
      do: {:ok, opts},
      else: {:error, "field must be an attribute name"}
  end

  @impl true
  def change(changeset, opts, _context) do
    field = opts[:field]

    case value(changeset, field) do
      nil -> changeset
      value -> if given?(changeset, field), do: changeset, else: put(changeset, field, value)
    end
  end

  # An atomic update gets the value the same way: in the argument, for the host's sealer to
  # find, or as the attribute's atomic value. Already given (or carried over from the
  # non-atomic pass an atomic upgrade re-runs) means nothing to do.
  @impl true
  def atomic(changeset, opts, _context) do
    field = opts[:field]

    case value(changeset, field) do
      nil ->
        {:ok, changeset}

      value ->
        cond do
          given?(changeset, field) ->
            {:ok, changeset}

          argument?(changeset, field) ->
            {:ok, Ash.Changeset.set_argument(changeset, field, value)}

          true ->
            {:atomic, %{field => value}}
        end
    end
  end

  defp value(changeset, field) do
    case changeset.context do
      %{paper: %{} = paper} -> Map.get(paper, field)
      _other -> nil
    end
  end

  defp given?(changeset, field) do
    if argument?(changeset, field),
      do: match?({:ok, _}, Ash.Changeset.fetch_argument(changeset, field)),
      else: Ash.Changeset.changing_attribute?(changeset, field)
  end

  defp put(changeset, field, value) do
    if argument?(changeset, field),
      do: Ash.Changeset.set_argument(changeset, field, value),
      else: Ash.Changeset.change_attribute(changeset, field, value)
  end

  defp argument?(%{action: %{arguments: arguments}}, field),
    do: Enum.any?(arguments, &(&1.name == field))

  defp argument?(_changeset, _field), do: false
end
