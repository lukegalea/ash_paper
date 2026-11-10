defmodule AshPaper.Fragment.StoredValue do
  @moduledoc "The value already stored must equal `value`, whatever this action is changing it to."

  use Ash.Resource.Validation

  require Ash.Expr
  import Ash.Expr

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, opts, _context) do
    if Map.get(changeset.data, opts[:attribute]) == opts[:value],
      do: :ok,
      else: {:error, error(opts)}
  end

  @impl true
  def atomic(_changeset, opts, _context) do
    attribute = opts[:attribute]

    {:atomic, [attribute], expr(^ref(attribute) != ^opts[:value]),
     expr(
       error(^Ash.Error.Changes.InvalidAttribute, %{
         field: ^attribute,
         message: ^message(opts),
         value: ^ref(attribute)
       })
     )}
  end

  defp error(opts),
    do:
      Ash.Error.Changes.InvalidAttribute.exception(
        field: opts[:attribute],
        message: message(opts)
      )

  defp message(opts), do: "must still be #{opts[:value]}"
end
