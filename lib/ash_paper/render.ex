defmodule AshPaper.Render do
  @moduledoc """
  `render(layout, theme, payload, clauses ; engine, fonts) -> bytes`.

  Pure given its pins. Limits are required, and any compiler warning is a failure: Typst warns
  rather than errors on a missing font, which would change a document silently.

  A second compile collects where every labelled block landed. It must produce identical page
  content, and the issued bytes carry no trace of it.
  """

  alias AshPaper.{Canonical, Fonts, Layout, Payload, Theme}
  alias AshPaper.Pdf.{Reader, Text}
  alias AshTypst.{Context, Isolated}

  defmodule Rendered do
    @moduledoc "A finished render: the bytes, where each block landed, and what produced it."
    @enforce_keys [
      :bytes,
      :digest,
      :page_count,
      :marks,
      :pins,
      :layout_hash,
      :theme_hash,
      :document_id
    ]
    defstruct @enforce_keys
  end

  @marks_file "paper-marks.json"

  @spec render(module() | Layout.t(), Theme.t(), Payload.t(), [map()], keyword()) ::
          {:ok, %Rendered{}} | {:error, term()}
  def render(layout, %Theme{} = theme, %Payload{} = payload, clauses, opts) do
    with {:ok, limits} <- limits(opts) do
      layout = Layout.of(layout)
      fonts = Keyword.get(opts, :fonts, Fonts.dir())
      pins = pins(fonts)
      document = Canonical.encode(Payload.document(payload, clauses))
      theme_json = Canonical.encode(Theme.tokens(theme))

      document_id =
        binary_part(
          Canonical.hash(%{
            layout: layout.hash,
            theme: Theme.hash(theme),
            document: Canonical.sha256(document),
            pins: pins
          }),
          0,
          32
        )

      job = %{
        layout: layout,
        theme_json: theme_json,
        document: document,
        document_id: document_id,
        limits: limits
      }

      context = [
        root: Application.app_dir(:ash_paper, "priv/typst"),
        font_paths: [fonts],
        ignore_system_fonts: true
      ]

      with {:ok, {bytes, page_count, marks}} <- bounded(job, context, opts) do
        {:ok,
         %Rendered{
           bytes: bytes,
           digest: Canonical.sha256(bytes),
           page_count: page_count,
           marks: marks,
           pins: pins,
           layout_hash: layout.hash,
           theme_hash: Theme.hash(theme),
           document_id: document_id
         }}
      end
    end
  end

  @doc "What a render is only reproducible within."
  @spec pins(String.t()) :: map()
  def pins(fonts \\ Fonts.dir()) do
    %{
      "typst" => AshTypst.NIF.typst_version(),
      "ash_typst" => to_string(Application.spec(:ash_typst, :vsn)),
      "fonts" => Fonts.pin(fonts),
      "paper_lib" =>
        Canonical.sha256(File.read!(Application.app_dir(:ash_paper, "priv/typst/paper.typ")))
    }
  end

  defp limits(opts) do
    case {Keyword.get(opts, :max_pages), Keyword.get(opts, :timeout_ms)} do
      {pages, timeout}
      when is_integer(pages) and pages > 0 and is_integer(timeout) and timeout > 0 ->
        {:ok, %{max_pages: pages, timeout_ms: timeout}}

      _missing ->
        {:error, :limits_required}
    end
  end

  defp bounded(job, context, opts) do
    isolate? = Keyword.get(opts, :isolate?, true)
    task = Task.async(fn -> run(job, context, isolate?) end)

    case Task.yield(task, job.limits.timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:engine_crashed, reason}}
      nil -> {:error, :timeout}
    end
  end

  defp run(job, context, true) do
    Isolated.with_context(context, &compile_both(&1, job))
  rescue
    error in Isolated.Error -> {:error, {:engine_crashed, error.reason}}
  end

  defp run(job, context, false) do
    {:ok, ctx} = Context.new(context)
    compile_both(ctx, job)
  end

  defp compile_both(ctx, job) do
    with :ok <- Context.set_virtual_file(ctx, "payload.json", job.document),
         :ok <- Context.set_virtual_file(ctx, "theme.json", job.theme_json),
         :ok <- Context.set_markup(ctx, job.layout.source),
         {:ok, issued, pages} <- pass(ctx, "0", job),
         {:ok, marked, _pages} <- pass(ctx, "1", job),
         :ok <- same_pages(issued, marked),
         {:ok, marks} <- marks(marked) do
      {:ok, {issued, pages, marks}}
    end
  end

  defp pass(ctx, marks, job) do
    with :ok <- Context.set_inputs(ctx, %{"paper_marks" => marks}),
         {:ok, %{warnings: [], page_count: pages}} <- Context.compile(ctx),
         :ok <- within(pages, job.limits.max_pages),
         {:ok, bytes} <- Context.export_pdf(ctx, document_id: job.document_id) do
      {:ok, bytes, pages}
    else
      {:ok, %{warnings: warnings}} -> {:error, {:warnings, warnings}}
      {:error, _} = error -> error
      other -> {:error, {:compile_failed, other}}
    end
  end

  defp within(pages, max) when pages <= max, do: :ok
  defp within(pages, max), do: {:error, {:too_many_pages, pages, max}}

  defp same_pages(issued, marked) do
    with {:ok, a} <- Text.page_streams(issued),
         {:ok, b} <- Text.page_streams(marked) do
      if a == b, do: :ok, else: {:error, :marks_changed_the_layout}
    end
  end

  defp marks(bytes) do
    with {:ok, doc} <- Reader.read(bytes),
         root = Reader.resolve(doc, doc.trailer["Root"]),
         %{} = names <- Reader.resolve(doc, root["Names"]),
         %{"Names" => [{:string, @marks_file}, spec]} <-
           Reader.resolve(doc, names["EmbeddedFiles"]),
         %{"EF" => ef} <- Reader.resolve(doc, spec),
         %{"F" => file} <- Reader.resolve(doc, ef),
         {:ok, json} <- Reader.stream_data(doc, file) do
      {:ok, Jason.decode!(json)}
    else
      _other -> {:error, :marks_unavailable}
    end
  end
end
