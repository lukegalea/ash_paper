defmodule AshPaper.Layout do
  @moduledoc """
  A document's structure: Typst source a host owns, reviewed as code and locked by hash.

      defmodule MyApp.Paper.Letter do
        use AshPaper.Layout, key: :letter, version: 1, path: Path.expand("letter.typ", __DIR__)
      end

  The lint runs at compile time. It is a backstop for code review, not a sandbox: the compile
  also runs with no filesystem beyond the kernel's own library and no system fonts.
  """

  @enforce_keys [:key, :version, :source, :hash]
  defstruct @enforce_keys

  @type t :: %__MODULE__{}

  @forbidden [
    {~r/\beval\s*\(/, "eval"},
    {~r/\bread\s*\(/, "read"},
    {~r/\bdatetime\.today\b/, "datetime.today"},
    {~r/\bsys\./, "sys"},
    {~r/\bplugin\s*\(/, "plugin"},
    {~r/\b(json|yaml|toml|csv|xml|cbor|image)\s*\(/, "file access"},
    {~r/\binclude\s+"/, "include"}
  ]

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      path = Keyword.fetch!(opts, :path)
      @external_resource path
      @paper_layout AshPaper.Layout.compile!(
                      Keyword.fetch!(opts, :key),
                      Keyword.fetch!(opts, :version),
                      File.read!(path)
                    )

      @doc false
      def __paper_layout__, do: @paper_layout
    end
  end

  @doc false
  def compile!(key, version, source) do
    case lint(source) do
      [] ->
        %__MODULE__{
          key: key,
          version: version,
          source: source,
          hash: AshPaper.Canonical.sha256(source)
        }

      problems ->
        raise CompileError, description: "layout #{key}: #{Enum.join(problems, "; ")}"
    end
  end

  @spec lint(String.t()) :: [String.t()]
  def lint(source) do
    forbidden =
      for {pattern, name} <- @forbidden, Regex.match?(pattern, source), do: "forbids #{name}"

    imports =
      Regex.scan(~r/#?\bimport\s+"([^"]+)"/, source, capture: :all_but_first) |> List.flatten()

    bad_imports = for name <- imports, name != "paper.typ", do: "imports #{name}"

    finish =
      if Regex.match?(~r/paper-finish\(\)/, source), do: [], else: ["never calls paper-finish()"]

    forbidden ++ bad_imports ++ finish
  end

  @spec of(module() | t()) :: t()
  def of(%__MODULE__{} = layout), do: layout
  def of(module) when is_atom(module), do: module.__paper_layout__()
end
