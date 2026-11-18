defmodule AshPaper.HostTest do
  @moduledoc """
  What a host needs to store a render and come back to it: the payload from its stored
  document, the block reader, the payload hash, the stored snapshot and its pins, the binding
  check and stored clauses.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  import AshPaper.Test.Build

  alias AshOpenLineage.Snapshot.Definition
  alias AshPaper.{Binding, Clause, Payload, Snapshot, Verify}
  alias AshPaper.Test.{ContractSchema, Letter, NoticeSchema, SummarySchema}

  @key String.duplicate("k", 32)
  @pins %{
    "typst" => "0.0.0-test",
    "ash_typst" => "0.0.0",
    "fonts" => String.duplicate("f", 64),
    "paper_lib" => String.duplicate("p", 64)
  }
  @intro %Clause{
    key: "intro",
    locale: :en,
    version: 2,
    runs: [{:text, "Dear "}, {:hole, "vendor"}, {:text, "."}]
  }

  defp json(value), do: value |> Jason.encode!() |> Jason.decode!()

  defp snapshot(schema, payload, opts \\ []) do
    Snapshot.build(
      Keyword.merge(
        [
          id: "run-1",
          schema: schema,
          layout: Letter,
          theme: theme(),
          payload: payload,
          pins: @pins,
          at: ~U[2026-11-09 00:00:00Z],
          authority: %{tenant: nil, actor_id: nil, completeness: :complete},
          hash_key: @key
        ],
        opts
      )
    )
  end

  describe "payload from its stored document" do
    test "a stored document re-renders to the same bytes, its clauses read back" do
      payload = payload()
      {:ok, clauses} = Clause.resolve([@intro], ["intro"], payload)
      {:ok, original} = render(payload, theme(), clauses)

      document = json(Payload.document(payload, clauses))
      {:ok, restored} = Payload.from_document(document, json(payload.facts), NoticeSchema)
      stored_clauses = Payload.document_clauses(document)

      assert restored == payload
      assert stored_clauses == clauses
      {:ok, again} = render(restored, theme(), stored_clauses)
      assert again.digest == original.digest

      assert Verify.read_back(again.bytes, again.marks, restored, stored_clauses, theme()).status ==
               :passed
    end

    test "tables and an in-memory document round-trip too" do
      payload = payload(SummarySchema, summary(4), :en)
      document = Payload.document(payload, [])

      assert {:ok, ^payload} = Payload.from_document(document, payload.facts, SummarySchema)

      assert {:ok, ^payload} =
               Payload.from_document(json(document), json(payload.facts), SummarySchema)

      assert Payload.document_clauses(document) == []
      assert Payload.document_clauses(%{}) == []
    end

    test "names every missing part, and refuses a locale that is not an atom" do
      document = json(Payload.document(payload(), []))

      assert {:error, {:incomplete, [:title, :labels]}} =
               document
               |> Map.drop(["title", "labels"])
               |> Payload.from_document(%{}, NoticeSchema)

      assert {:error, {:unknown_locale, "zz-no-such-locale-atom"}} =
               document
               |> Map.put("locale", "zz-no-such-locale-atom")
               |> Payload.from_document(%{}, NoticeSchema)

      assert {:error, {:unknown_locale, "nil"}} =
               document |> Map.put("locale", "nil") |> Payload.from_document(%{}, NoticeSchema)
    end

    property "a payload survives its stored document, as JSON, unchanged" do
      check all(
              vendor <- string(:printable, min_length: 1, max_length: 40),
              vendor = String.trim(vendor),
              vendor != "",
              cents <- integer(0..100_000_000),
              months <- integer(1..120),
              locale <- member_of([:en, :fr]),
              currency <- member_of([:CAD, :EUR, :USD])
            ) do
        source =
          notice(%{
            vendor: vendor,
            fee: Money.new!(currency, Decimal.new(cents) |> Decimal.div(100)),
            term_months: months
          })

        payload = payload(NoticeSchema, source, locale)
        document = json(Payload.document(payload, []))

        assert {:ok, ^payload} =
                 Payload.from_document(document, json(payload.facts), NoticeSchema)
      end
    end
  end

  describe "block reader" do
    defp agrees(payload, clauses) do
      {:ok, rendered} = render(payload, theme(), clauses)
      {:ok, read} = Verify.blocks(rendered.bytes, rendered.marks, theme())
      outcome = Verify.read_back(rendered.bytes, rendered.marks, payload, clauses, theme())
      {read, outcome}
    end

    test "reads every block read-back checks, with the text it checks" do
      payload = payload()
      clauses = [%{key: "terms", text: "Pay within thirty days."}]
      {read, outcome} = agrees(payload, clauses)

      assert outcome.status == :passed
      assert read.order == Enum.map(payload.field_order, &"field:#{&1}") ++ ["clause:terms"]
      assert map_size(read.blocks) == outcome.checked
      assert read.blocks["clause:terms"].text == "Pay within thirty days."

      assert read.blocks["field:vendor"] == %{
               kind: "field",
               key: "vendor",
               page: 1,
               text: "Vendor: Northwind Elevators"
             }

      for key <- payload.field_order do
        text = Verify.squash(read.blocks["field:#{key}"].text)
        assert String.contains?(text, Verify.squash(payload.fields[key]))
      end

      assert read.pages == 1
      assert read.furniture == "1 / 1"
    end

    test "reads table rows across pages, in document order" do
      payload = payload(SummarySchema, summary(60), :en)
      {read, outcome} = agrees(payload, [])

      assert outcome.status == :passed
      assert read.pages >= 2
      rows = Enum.filter(read.order, &String.starts_with?(&1, "row:"))
      assert rows == for(i <- 0..59, do: "row:lines/#{i}")
      assert Enum.any?(rows, &(read.blocks[&1].page > 1))
      assert outcome.checked == 2 + 60
    end

    test "the block read-back finds wrong is the block whose text lacks the value" do
      payload = payload()
      {:ok, rendered} = render(payload, theme())
      {:ok, read} = Verify.blocks(rendered.bytes, rendered.marks, theme())

      swapped = %{
        payload
        | fields: %{
            payload.fields
            | "vendor" => payload.fields["property"],
              "property" => payload.fields["vendor"]
          }
      }

      outcome = Verify.read_back(rendered.bytes, rendered.marks, swapped, [], theme())

      lacking =
        for key <- swapped.field_order,
            not String.contains?(
              Verify.squash(read.blocks["field:#{key}"].text),
              Verify.squash(swapped.fields[key])
            ),
            do: {:mismatch, :field, key}

      assert outcome.problems == lacking
      assert lacking != []
    end

    test "no marks reads no blocks; unreadable bytes are an error" do
      payload = payload()
      {:ok, rendered} = render(payload, theme())
      assert {:ok, %{blocks: blocks, order: []}} = Verify.blocks(rendered.bytes, [], theme())
      assert blocks == %{}
      assert Verify.read_back(rendered.bytes, [], payload, [], theme()).status == :unmeasured
      assert {:error, _} = Verify.blocks("not a pdf", rendered.marks, theme())
    end

    test "a block whose end mark is gone has no text, and read-back cannot measure it" do
      payload = payload()
      {:ok, rendered} = render(payload, theme())

      marks =
        Enum.reject(
          rendered.marks,
          &(&1["value"] == %{"kind" => "field", "key" => "fee", "edge" => "end"})
        )

      {:ok, read} = Verify.blocks(rendered.bytes, marks, theme())
      assert read.blocks["field:fee"].text == nil
      outcome = Verify.read_back(rendered.bytes, marks, payload, [], theme())
      assert outcome.problems == [{:unmeasured, "field", "fee"}]
    end
  end

  describe "snapshot" do
    test "digests for existing inputs are unchanged" do
      payload = payload()
      summary = payload(SummarySchema, summary(3), :en)

      assert snapshot(NoticeSchema, payload).digest ==
               "460f50a45dc240f6cad53dbfb7ba884e4b9d54db3f5d0f4f053668e37a0daad3"

      assert snapshot(NoticeSchema, payload, clauses: [@intro]).digest ==
               "9fb73ca33a895b45c8ce79a53386db6cd79e28e9052804a7757d7ac6a8dcfd94"

      assert snapshot(SummarySchema, summary).digest ==
               "559c2b9b9be4bd288efdee21bb834f93f2e42fb763aba964f1237fd6e5e1cd6f"

      assert snapshot(NoticeSchema, payload, definitions: []).digest ==
               snapshot(NoticeSchema, payload).digest
    end

    test "the payload hash is the one the snapshot embeds, and survives storage" do
      payload = payload()
      assert Snapshot.payload_hash(@key, payload) == snapshot(NoticeSchema, payload).payload_hash

      assert Snapshot.payload_hash(@key, payload) ==
               "6a15b8833f9e6888408230b0821f69044cc80e6c8a7c9c4061a0e22af1be0854"

      document = json(Payload.document(payload, []))
      {:ok, restored} = Payload.from_document(document, json(payload.facts), NoticeSchema)
      assert Snapshot.payload_hash(@key, restored) == Snapshot.payload_hash(@key, payload)

      refute Snapshot.payload_hash(String.duplicate("j", 32), payload) ==
               Snapshot.payload_hash(@key, payload)
    end

    test "extra definitions are pinned after the derived ones and move the digest" do
      payload = payload()
      plain = snapshot(NoticeSchema, payload)

      decision = %Definition{
        kind: :dmn,
        key: "fee.band",
        version: "3",
        content_hash: String.duplicate("d", 64)
      }

      pinned = snapshot(NoticeSchema, payload, definitions: [decision])
      assert pinned.definitions == plain.definitions ++ [decision]
      refute pinned.digest == plain.digest

      assert pinned.digest ==
               AshOpenLineage.Snapshot.put_digest(%{
                 plain
                 | definitions: plain.definitions ++ [decision]
               }).digest

      assert_raise ArgumentError, fn ->
        snapshot(NoticeSchema, payload, definitions: [%{kind: :dmn}])
      end
    end

    test "the stored form survives JSON, and its pins read back out" do
      payload = payload()
      snap = snapshot(NoticeSchema, payload, clauses: [@intro])
      stored = Snapshot.stored(snap)

      assert stored["digest"] == snap.digest
      assert json(stored) == stored
      assert stored["snapshot"]["payload_hash"] == snap.payload_hash

      assert [%{"key" => "acme", "content_hash" => hash, "version" => "1"}] =
               Snapshot.pinned(stored, :theme)

      assert hash == AshPaper.Theme.hash(theme())
      assert [%{"key" => "intro/en", "version" => "2"}] = Snapshot.pinned(stored, "clause")
      assert length(Snapshot.pinned(stored, :engine)) == map_size(@pins)
      assert Snapshot.pinned(stored, :dmn) == []
      assert Snapshot.pinned(nil, :theme) == []
      assert Snapshot.pinned(%{"snapshot" => %{}}, :theme) == []
    end
  end

  describe "binding check" do
    defp themes, do: %{"acme" => theme()}

    test "a fresh selection gives its theme, stored or not" do
      selection = Binding.selection(NoticeSchema, Letter, theme(), [@intro])
      assert {:ok, theme} = Binding.check(selection, NoticeSchema, Letter, themes())
      assert theme == theme()
      assert {:ok, ^theme} = Binding.check(json(selection), NoticeSchema, Letter, &themes()[&1])
    end

    test "is stale when the theme, schema or layout moved, or the theme is gone" do
      selection = Binding.selection(NoticeSchema, Letter, theme(), [])
      stale = {:error, {:binding_stale, selection}}

      assert Binding.check(selection, NoticeSchema, Letter, %{
               "acme" => theme("Carlito", "#000000")
             }) == stale

      assert Binding.check(selection, ContractSchema, Letter, themes()) == stale
      other_layout = %AshPaper.Layout{key: :letter, version: 1, source: "", hash: "other"}
      assert Binding.check(selection, NoticeSchema, other_layout, themes()) == stale
      assert Binding.check(selection, NoticeSchema, Letter, fn _key -> nil end) == stale

      without_theme = Enum.reject(selection, &(&1["kind"] == "theme"))

      assert Binding.check(without_theme, NoticeSchema, Letter, themes()) ==
               {:error, {:binding_stale, without_theme}}

      assert Binding.check(nil, NoticeSchema, Letter, themes()) == {:error, {:binding_stale, nil}}
    end
  end

  describe "stored clauses" do
    test "a clause stored as JSON comes back as the clause, with the same hash" do
      stored = %{
        "key" => "intro",
        "locale" => "en",
        "version" => 2,
        "runs" => [
          %{"kind" => "text", "value" => "Dear "},
          %{"kind" => "hole", "value" => "vendor"},
          %{"kind" => "text", "value" => "."}
        ]
      }

      assert {:ok, @intro} = Clause.from_stored(stored)
      assert Clause.from_stored!(stored) == @intro
      assert Clause.hash(Clause.from_stored!(stored)) == Clause.hash(@intro)

      atoms = %{
        key: "intro",
        locale: :en,
        version: 2,
        runs: [
          %{kind: :text, value: "Dear "},
          %{kind: :hole, value: "vendor"},
          %{kind: "text", value: "."}
        ]
      }

      assert {:ok, @intro} = Clause.from_stored(atoms)
    end

    test "refuses what is not a stored clause, naming the part" do
      good = %{"key" => "k", "locale" => "en", "version" => 1, "runs" => []}
      assert {:ok, %Clause{runs: []}} = Clause.from_stored(good)
      assert {:error, {:invalid, :key}} = Clause.from_stored(Map.delete(good, "key"))
      assert {:error, {:invalid, :locale}} = Clause.from_stored(%{good | "locale" => "zz-nope"})
      assert {:error, {:invalid, :version}} = Clause.from_stored(%{good | "version" => 0})

      assert {:error, {:invalid, :runs}} =
               Clause.from_stored(%{good | "runs" => [%{"kind" => "eval", "value" => "x"}]})

      assert_raise ArgumentError, fn -> Clause.from_stored!(Map.delete(good, "runs")) end
    end

    test "valid runs are text and hole maps with string values" do
      assert Clause.valid_runs?([])
      assert Clause.valid_runs?([%{"kind" => "text", "value" => "a"}, %{kind: :hole, value: "b"}])
      refute Clause.valid_runs?([%{"kind" => "hole", "value" => 1}])
      refute Clause.valid_runs?([%{"kind" => "text"}])
      refute Clause.valid_runs?([{:text, "a"}])
      refute Clause.valid_runs?(nil)
    end
  end
end
