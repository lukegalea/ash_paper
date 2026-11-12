defmodule AshPaper.KernelTest do
  use ExUnit.Case, async: true

  import AshPaper.Test.Build

  alias AshPaper.{Clause, Layout, Lock, Payload, Schema, Snapshot, Theme}
  alias AshPaper.Test.{ContractSchema, Letter, NoticeSchema, Run, SummarySchema}

  describe "payload" do
    test "names every required value that is absent" do
      assert {:error, problems} =
               Payload.build(NoticeSchema, notice(%{vendor: nil, fee: nil}),
                 title: "t",
                 locale: :en
               )

      assert {:missing, "vendor"} in problems
      assert {:missing, "fee"} in problems
    end

    test "omits an absent optional value" do
      refute "note" in payload().field_order
    end

    test "never invents a currency" do
      assert {:error, [{:no_currency, "income"}]} =
               Payload.build(SummarySchema, %{summary() | currency: nil}, title: "t", locale: :en)

      assert {:error, [{:no_currency, "income"}]} =
               Payload.build(SummarySchema, %{summary() | currency: "NOPE"},
                 title: "t",
                 locale: :en
               )
    end

    test "a bare number is not money" do
      assert {:error, [{:wrong_type, "fee"}]} =
               Payload.build(NoticeSchema, notice(%{fee: 12}), title: "t", locale: :en)
    end

    test "reports an unloaded relationship" do
      source = %{title: "x", vendor: %Ash.NotLoaded{field: :name}}

      assert {:error, [{:not_loaded, "vendor"}]} =
               Payload.build(ContractSchema, source, title: "t", locale: :en)
    end

    test "freezes typed facts beside display strings" do
      payload = payload(SummarySchema, summary(2))
      assert payload.facts["fields"]["income"] == %{"amount" => "120000.25", "currency" => "USD"}

      assert [%{"amount" => %{"amount" => "1000.10", "currency" => "CAD"}}, _] =
               payload.facts["tables"]["lines"]
    end
  end

  describe "schema" do
    defp verify(module), do: AshPaper.Schema.Verifiers.ReadPaths.verify(module.spark_dsl_config())

    defp compile_quietly(fun), do: ExUnit.CaptureIO.capture_io(:stderr, fun)

    test "refuses a read path that does not exist" do
      compile_quietly(fn ->
        defmodule BadField do
          use AshPaper.Schema

          paper do
            key :bad
            version 1
            resource AshPaper.Test.Contract
            field :title, :text, path: [:nope], label: "x"
          end
        end
      end)

      assert {:error, %Spark.Error.DslError{message: message}} = verify(__MODULE__.BadField)
      assert message =~ "nope is not a field"
      assert [problem] = Lock.path_problems([__MODULE__.BadField])
      assert problem =~ "nope is not a field"
    end

    test "refuses a path through a to-many relationship" do
      compile_quietly(fn ->
        defmodule BadMany do
          use AshPaper.Schema

          paper do
            key :bad
            version 1
            resource AshPaper.Test.Vendor
            field :title, :text, path: [:contracts, :title], label: "x"
          end
        end
      end)

      assert {:error, %Spark.Error.DslError{message: message}} = verify(__MODULE__.BadMany)
      assert message =~ "holds many rows"
    end

    test "accepts a good path" do
      assert :ok = verify(ContractSchema)
    end

    test "its hash changes with its declaration" do
      assert Schema.hash(NoticeSchema) != Schema.hash(SummarySchema)
    end
  end

  describe "layout lint" do
    for {name, line} <- [
          eval: "#eval(\"1\")",
          read: "#read(\"x\")",
          today: "#datetime.today()",
          sys: "#sys.inputs",
          json: "#json(\"x\")",
          image: "#image(\"x\")",
          plugin: "#plugin(\"x\")",
          include: "#include \"x.typ\""
        ] do
      test "refuses #{name}" do
        assert [_ | _] = Layout.lint(unquote(line) <> "\n#paper-finish()")
      end
    end

    test "refuses other imports and a missing finish" do
      assert Layout.lint("#import \"other.typ\": *\n#paper-finish()") == ["imports other.typ"]
      assert Layout.lint("hello") == ["never calls paper-finish()"]
      assert Layout.lint(Layout.of(Letter).source) == []
    end
  end

  describe "theme" do
    test "refuses unknown tokens, unknown fonts and bad values" do
      assert {:error, problems} =
               Theme.new(%{
                 key: "a",
                 version: 1,
                 body_font: "Comic Sans",
                 heading_font: "Carlito",
                 body_size: 99,
                 margin_x: 72,
                 margin_y: 72,
                 paper: "us-letter",
                 accent: "red",
                 typst: "#panic()"
               })

      assert {:unknown_token, :typst} in problems
      assert {:invalid_token, :body_font} in problems
      assert {:invalid_token, :body_size} in problems
      assert {:invalid_token, :accent} in problems
    end

    test "reports a missing token" do
      assert {:error, problems} = Theme.new(%{key: "a"})
      assert {:missing_token, :accent} in problems
    end

    test "optional look tokens are validated, and paragraph spacing needs line spacing" do
      assert {:ok, %Theme{line_spacing: 1.4, table_header_fill: "#dcebec"}} =
               Theme.new(Map.merge(base_tokens(), look_tokens()))

      assert {:error, problems} =
               Theme.new(
                 Map.merge(base_tokens(), %{
                   text_color: "black",
                   heading_size: 99,
                   line_spacing: 3,
                   title_rule: -1,
                   table_stroke: "#12345"
                 })
               )

      for token <- [:text_color, :heading_size, :line_spacing, :title_rule, :table_stroke],
          do: assert({:invalid_token, token} in problems)

      assert {:error, [{:requires_token, :paragraph_spacing, :line_spacing}]} =
               Theme.new(Map.put(base_tokens(), :paragraph_spacing, 8))
    end

    test "a theme without optional tokens hashes as it did before they existed" do
      assert Theme.new(Map.put(base_tokens(), :text_color, nil)) == Theme.new(base_tokens())
      refute Map.has_key?(Theme.tokens(theme()), :text_color)

      # Theme.hash(theme()) on the kernel before the optional tokens (5ab3222).
      assert Theme.hash(theme()) ==
               "fa82fea2c6677ea4c0156a563cf6376d3f536724730acf2ebecf74f2e39e34d6"
    end

    test "a fully themed render reads back, and line spacing is baseline to baseline" do
      {:ok, looked} = Theme.new(Map.merge(base_tokens(), look_tokens()))

      clause = %Clause{
        key: "renewal",
        locale: :en,
        version: 1,
        runs: [{:text, String.duplicate("Either party may decline by written notice. ", 12)}]
      }

      p = payload()
      {:ok, resolved} = Clause.resolve([clause], ["renewal"], p)
      {:ok, r} = render(p, looked, resolved)
      assert AshPaper.Verify.read_back(r.bytes, r.marks, p, resolved, looked).status == :passed

      s = payload(SummarySchema, summary(8))
      {:ok, table} = render(s, looked)
      assert AshPaper.Verify.read_back(table.bytes, table.marks, s, [], looked).status == :passed

      [start, stop] =
        for edge <- ["start", "end"],
            do:
              Enum.find(
                r.marks,
                &(&1["value"] == %{"kind" => "clause", "key" => "renewal", "edge" => edge})
              )

      {:ok, runs, _heights} = AshPaper.Pdf.Text.runs(r.bytes)

      tops =
        for run <- runs,
            run.page == start["page"],
            run.top >= start["y"] - 3 and run.top <= stop["y"] + 0.5,
            uniq: true,
            do: Float.round(run.top * 1.0, 2)

      pitches =
        tops
        |> Enum.sort()
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.map(fn [a, b] -> b - a end)

      assert length(pitches) >= 2
      for pitch <- pitches, do: assert_in_delta(pitch, 1.4 * 11, 0.05)
    end
  end

  defp base_tokens do
    %{
      key: "a",
      version: 1,
      body_font: "Carlito",
      heading_font: "Caladea",
      body_size: 11,
      margin_x: 65,
      margin_y: 54,
      paper: "us-letter",
      accent: "#0b5563"
    }
  end

  defp look_tokens do
    %{
      text_color: "#222222",
      muted_color: "#6b7280",
      heading_size: 16,
      line_spacing: 1.4,
      paragraph_spacing: 8,
      title_rule: 1.5,
      table_stroke: "#9fb8bb",
      table_header_fill: "#dcebec",
      table_header_text: "#0b5563"
    }
  end

  describe "clauses" do
    test "a missing locale variant blocks" do
      clause = %Clause{key: "a", locale: :en, version: 1, runs: [{:text, "x"}]}

      assert {:error, [{:missing_locale, "a", :fr}]} =
               Clause.resolve([clause], ["a"], payload(NoticeSchema, notice(), :fr))
    end

    test "a hole with no value blocks" do
      clause = %Clause{key: "a", locale: :en, version: 1, runs: [{:hole, "note"}]}

      assert {:error, [{:unfilled_holes, "a", ["note"]}]} =
               Clause.resolve([clause], ["a"], payload())
    end
  end

  describe "lock" do
    test "refuses a changed hash at the same version and keeps history on a bump" do
      old = %{"schema:a" => %{"version" => 1, "hash" => "h1", "history" => %{}}}
      assert {:error, [_]} = Lock.merge(old, %{"schema:a" => %{"version" => 1, "hash" => "h2"}})

      assert {:ok, %{"schema:a" => %{"history" => %{"1" => "h1"}}}} =
               Lock.merge(old, %{"schema:a" => %{"version" => 2, "hash" => "h2"}})
    end

    test "reports read-path problems, which a plain compile only warns about" do
      assert Lock.path_problems([ContractSchema]) == []
    end

    test "covers schemas and layouts" do
      entries = Lock.entries(schemas: [NoticeSchema], layouts: [Letter])
      assert Map.keys(entries) == ["layout:letter", "schema:notice"]
    end
  end

  test "a binding selection is in the shape the temporal binding stores" do
    selection = AshPaper.Binding.selection(NoticeSchema, Letter, theme(), [])
    assert Enum.map(selection, & &1["kind"]) == ["layout", "schema", "theme"]
    assert Enum.all?(selection, &(Map.keys(&1) == ["content_hash", "key", "kind", "version"]))
  end

  describe "snapshot" do
    defp snapshot(key) do
      payload = payload()
      {:ok, rendered} = render(payload, theme())

      Snapshot.build(
        id: "run-1",
        schema: NoticeSchema,
        layout: Letter,
        theme: theme(),
        payload: payload,
        pins: rendered.pins,
        at: ~U[2026-11-09 00:00:00Z],
        authority: %{tenant: nil, actor_id: nil, completeness: :complete},
        hash_key: key
      )
    end

    test "pins every axis and the engine, and its digest is stable" do
      a = snapshot(String.duplicate("k", 32))
      assert a.digest == snapshot(String.duplicate("k", 32)).digest
      kinds = a.definitions |> Enum.map(& &1.kind) |> Enum.uniq()
      assert kinds == [:schema, :layout, :theme, :engine]
    end

    test "the payload hash depends on the erasure key" do
      assert snapshot(String.duplicate("k", 32)).payload_hash !=
               snapshot(String.duplicate("j", 32)).payload_hash
    end
  end

  describe "run" do
    defp start,
      do:
        Run
        |> Ash.Changeset.for_create(:start, %{document_kind: "notice"})
        |> Ash.create!(authorize?: false)

    defp rendered(run) do
      run
      |> Ash.Changeset.for_update(:record_render, %{
        snapshot: %{a: 1},
        output_digest: String.duplicate("a", 64),
        payload: %{b: 1},
        facts: %{c: 1}
      })
      |> Ash.update!(authorize?: false)
    end

    defp read_back(run, status) do
      run
      |> Ash.Changeset.for_update(:record_read_back, %{read_back_status: status})
      |> Ash.update(authorize?: false)
    end

    test "a new run has not been read back" do
      run = start()
      assert run.render_status == :pending
      assert run.read_back_status == :not_run
    end

    test "records each axis once" do
      run = rendered(start())
      assert {:ok, %{read_back_status: :passed} = done} = read_back(run, :passed)
      assert {:error, _} = read_back(done, :failed)
    end

    test "cannot read back a render that never happened" do
      assert {:error, _} = read_back(start(), :passed)
    end

    test "cannot record :not_run as an outcome" do
      assert {:error, _} = read_back(rendered(start()), :not_run)
    end
  end
end
