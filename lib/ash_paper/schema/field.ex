defmodule AshPaper.Schema.Field do
  @moduledoc "One named value a document may show."
  defstruct [:name, :type, :path, :currency, :label, required?: true, __spark_metadata__: nil]
end
