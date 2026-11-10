defmodule AshPaper.Schema.Table do
  @moduledoc "A named list of rows and its columns."
  defstruct [:name, :path, columns: [], __spark_metadata__: nil]
end
