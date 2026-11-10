defmodule AshPaper.RenderTest do
  use ExUnit.Case, async: true

  import AshPaper.Test.Build

  alias AshPaper.{Clause, Layout, Render, Verify}
  alias AshPaper.Pdf.Text
  alias AshPaper.Test.{Letter, NoticeSchema, SummarySchema}

  @fr <<"Le fournisseur "::utf8>>

  defp clauses(payload) do
    {:ok, resolved} =
      Clause.resolve(
        [
          %Clause{
            key: "renewal",
            locale: :en,
            version: 1,
            runs: [
              {:text, "The agreement renews on "},
              {:hole, "renews_on"},
              {:text, " for a fee of "},
              {:hole, "fee"},
              {:text, " without limitation of any efficient final remedy."}
            ]
          },
          %Clause{
            key: "renewal",
            locale: :fr,
            version: 1,
            runs: [
              {:text, @fr},
              {:hole, "vendor"},
              {:text, " accepte le renouvellement le "},
              {:hole, "renews_on"},
              {:text, " moyennant "},
              {:hole, "fee"},
              {:text, ", à l’été."}
            ]
          }
        ],
        ["renewal"],
        payload
      )

    resolved
  end

  defp verified(payload, theme, clause_list) do
    {:ok, rendered} = render(payload, theme, clause_list)
    {rendered, Verify.read_back(rendered.bytes, rendered.marks, payload, clause_list, theme)}
  end

  test "equal inputs give equal bytes, and the outcome has content to check" do
    payload = payload()
    {:ok, a} = render(payload, theme())
    {:ok, b} = render(payload, theme())
    assert a.bytes == b.bytes
    assert a.digest == AshPaper.Canonical.sha256(a.bytes)
    assert a.pins["typst"] == "0.15.1"
  end

  test "an isolated render matches an in-VM render byte for byte" do
    payload = payload()
    {:ok, a} = render(payload, theme())
    {:ok, b} = render(payload, theme(), [], isolate?: true)
    assert a.bytes == b.bytes
  end

  test "a theme swap changes the bytes and no labelled block" do
    payload = payload()
    clause_list = clauses(payload)
    {a, a_check} = verified(payload, theme("Carlito"), clause_list)
    {b, b_check} = verified(payload, theme("Liberation Serif", "#7a1f1f"), clause_list)
    assert a.bytes != b.bytes
    assert a_check.status == :passed, inspect(a_check)
    assert b_check.status == :passed, inspect(b_check)
    assert a_check.checked == b_check.checked
  end

  test "a schema swap on one layout keeps the page furniture" do
    {:ok, a} = render(payload(), theme())
    {:ok, b} = render(payload(SummarySchema, summary()), theme())

    furniture = fn bytes ->
      {:ok, runs, heights} = Text.runs(bytes)
      for r <- runs, r.top > heights[r.page] - 72, do: {r.page, round(r.x), round(r.top), r.text}
    end

    assert a.page_count == b.page_count
    assert furniture.(a.bytes) == furniture.(b.bytes)
    assert furniture.(a.bytes) != []
  end

  test "English and French render and read back, with their own number formats" do
    fr = payload(NoticeSchema, notice(), :fr)
    assert fr.fields["fee"] == "4 575,50 CAD"
    assert fr.fields["renews_on"] == "1er mars 2027"
    {_rendered, check} = verified(fr, theme(), clauses(fr))
    assert check.status == :passed, inspect(check)
  end

  test "one table holds several currencies and every row reads back across pages" do
    payload = payload(SummarySchema, summary(120))
    {rendered, check} = verified(payload, theme(), [])
    assert rendered.page_count > 2
    assert check.status == :passed, inspect(Enum.take(check.problems, 3))
    assert check.checked == 122
    assert payload.fields["income"] == "USD 120,000.25"
    assert hd(payload.tables["lines"])["amount"] == "CAD 1,000.10"
  end

  test "a clause running across a page break reads back exactly" do
    long =
      String.duplicate(
        "The contractor shall maintain coverage throughout the term of this agreement. ",
        120
      )

    payload = payload()
    {rendered, check} = verified(payload, theme(), [%{key: "long", text: String.trim(long)}])
    assert rendered.page_count >= 2
    assert check.status == :passed, inspect(check)
  end

  describe "read-back fails rather than passing" do
    test "values swapped between two fields" do
      payload = payload()
      {:ok, rendered} = render(payload, theme())

      swapped = %{
        payload
        | fields: %{
            payload.fields
            | "vendor" => payload.fields["property"],
              "property" => payload.fields["vendor"]
          }
      }

      check = Verify.read_back(rendered.bytes, rendered.marks, swapped, [], theme())
      assert check.status == :failed
      assert {:mismatch, :field, "vendor"} in check.problems
    end

    test "a changed clause" do
      payload = payload()
      {:ok, rendered} = render(payload, theme(), [%{key: "c", text: "Pay within thirty days."}])

      check =
        Verify.read_back(
          rendered.bytes,
          rendered.marks,
          payload,
          [%{key: "c", text: "Pay within sixty days."}],
          theme()
        )

      assert check.status == :failed
    end

    test "marks that are missing are unmeasured" do
      payload = payload()
      {:ok, rendered} = render(payload, theme())
      assert Verify.read_back(rendered.bytes, [], payload, [], theme()).status == :unmeasured
    end

    test "bytes that cannot be read are unmeasured" do
      payload = payload()
      {:ok, rendered} = render(payload, theme())

      assert Verify.read_back("not a pdf", rendered.marks, payload, [], theme()).status ==
               :unmeasured
    end

    test "a page holding a form XObject is unmeasured, not silently short" do
      source = ~S"""
      #import "paper.typ": *
      #show: paper-setup
      #paper-fields()
      #place(rect(width: 10pt, height: 10pt, fill: gradient.linear(red, blue)))
      #image(bytes("<svg xmlns='http://www.w3.org/2000/svg' width='20' height='20'><g opacity='0.5'><text y='10'>hidden</text></g></svg>"), format: "svg")
      #paper-finish()
      """

      layout = %Layout{key: :x, version: 1, source: source, hash: "x"}
      payload = payload()

      {:ok, rendered} =
        Render.render(layout, theme(), payload, [],
          max_pages: 5,
          timeout_ms: 30_000,
          isolate?: false
        )

      check = Verify.read_back(rendered.bytes, rendered.marks, payload, [], theme())
      assert check.status == :unmeasured, inspect(check)
      assert [{:unreadable, {:unreadable, {:form_xobject, _}}}] = check.problems
    end
  end

  describe "render refuses" do
    test "without limits" do
      assert {:error, :limits_required} =
               Render.render(Letter, theme(), payload(), [], isolate?: false)

      assert {:error, :limits_required} =
               Render.render(Letter, theme(), payload(), [], max_pages: 2, isolate?: false)
    end

    test "more pages than allowed" do
      assert {:error, {:too_many_pages, _, 1}} =
               render(payload(SummarySchema, summary(200)), theme(), [], max_pages: 1)
    end

    test "past its time limit" do
      assert {:error, :timeout} = render(payload(), theme(), [], timeout_ms: 1, isolate?: true)
    end

    test "a layout that asks for a value the payload lacks" do
      source =
        "#import \"paper.typ\": *\n#show: paper-setup\n#paper-field(\"nope\")\n#paper-finish()\n"

      layout = %Layout{key: :x, version: 1, source: source, hash: "x"}

      assert {:error, _} =
               Render.render(layout, theme(), payload(), [],
                 max_pages: 5,
                 timeout_ms: 30_000,
                 isolate?: false
               )
    end

    test "any compiler warning" do
      source =
        "#import \"paper.typ\": *\n#show: paper-setup\n#text(font: \"No Such Font\")[x]\n#paper-finish()\n"

      layout = %Layout{key: :x, version: 1, source: source, hash: "x"}

      assert {:error, {:warnings, [_ | _]}} =
               Render.render(layout, theme(), payload(), [],
                 max_pages: 5,
                 timeout_ms: 30_000,
                 isolate?: false
               )
    end
  end

  test "clause text is data: markup in it is printed, not run" do
    payload = payload()
    text = "#panic(\"no\") *bold* $x$ and #eval(\"1\")"
    {_rendered, check} = verified(payload, theme(), [%{key: "m", text: text}])
    assert check.status == :passed, inspect(check)
  end
end
