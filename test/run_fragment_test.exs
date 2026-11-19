defmodule AshPaper.RunFragmentTest do
  use ExUnit.Case, async: true

  require Ash.Query

  alias AshPaper.Fragment.Run, as: Fragment
  alias AshPaper.Test.{Run, SealedRun}

  doctest AshPaper.Fragment.Run

  @key Base.encode64(String.duplicate("k", 32))
  @other_key Base.encode64(String.duplicate("j", 32))
  @version_id "0b0f9a1e-6d55-4f53-9c6e-0d7b3c1f2a10"
  @reasons [
    %{"key" => "late_fee", "version" => 2, "rule_id" => "r1", "reason" => "Fees apply late."}
  ]

  defp start(resource) do
    resource
    |> Ash.Changeset.for_create(:start, %{document_kind: "notice"})
    |> Ash.create!(authorize?: false)
  end

  defp inputs(extra \\ %{}) do
    Map.merge(
      %{
        snapshot: %{"digest" => "d"},
        output_digest: String.duplicate("a", 64),
        payload: %{"title" => "t"},
        facts: %{"fee" => "1"}
      },
      extra
    )
  end

  defp record_render(run, inputs, opts \\ []) do
    run
    |> Ash.Changeset.for_update(:record_render, inputs, opts)
    |> Ash.update(authorize?: false)
  end

  describe "the render record's fields" do
    test "the fragment declares them with the columns hosts already have" do
      key = Ash.Resource.Info.attribute(Run, :payload_hash_key)
      assert key.type == Ash.Type.String and key.allow_nil? and key.sensitive?
      assert key.default == nil

      version = Ash.Resource.Info.attribute(Run, :document_version_id)
      assert version.type == Ash.Type.UUID and version.allow_nil?
      assert version.default == nil
      refute Ash.Resource.Info.relationship(Run, :document_version)

      reasons = Ash.Resource.Info.attribute(Run, :clause_reasons)
      assert reasons.type == {:array, Ash.Type.Map}
      refute reasons.allow_nil?
      assert reasons.default == []
    end

    test "a new run has no key, no stored bytes and no reasons" do
      run = start(Run)
      assert run.payload_hash_key == nil
      assert run.document_version_id == nil
      assert run.clause_reasons == []
    end

    test "are accepted as inputs" do
      run =
        Run
        |> start()
        |> record_render(
          inputs(%{
            payload_hash_key: @key,
            document_version_id: @version_id,
            clause_reasons: @reasons
          })
        )
        |> then(fn {:ok, run} -> run end)

      assert run.render_status == :rendered
      assert run.payload_hash_key == @key
      assert run.document_version_id == @version_id
      assert run.clause_reasons == @reasons
    end

    test "the key and the reasons ride the context option" do
      assert {:ok, run} =
               Run
               |> start()
               |> record_render(inputs(),
                 context: %{paper: %{payload_hash_key: @key, clause_reasons: @reasons}}
               )

      assert run.payload_hash_key == @key
      assert run.clause_reasons == @reasons
    end

    test "an input wins over the context" do
      assert {:ok, run} =
               Run
               |> start()
               |> record_render(inputs(%{payload_hash_key: @key}),
                 context: %{paper: %{payload_hash_key: @other_key}}
               )

      assert run.payload_hash_key == @key
    end

    test "an atomic update takes them from the context too" do
      run = start(Run)

      assert %Ash.BulkResult{status: :success, records: [updated]} =
               Run
               |> Ash.Query.filter(id == ^run.id)
               |> Ash.bulk_update(:record_render, inputs(),
                 strategy: :atomic,
                 context: %{paper: %{payload_hash_key: @key, clause_reasons: @reasons}},
                 return_records?: true,
                 return_errors?: true,
                 authorize?: false
               )

      assert updated.payload_hash_key == @key
      assert updated.clause_reasons == @reasons
    end

    test "a render recorded without them keeps none" do
      assert {:ok, run} = Run |> start() |> record_render(inputs())
      assert run.payload_hash_key == nil
      assert run.clause_reasons == []
    end
  end

  describe "the payload hash key" do
    test "is written once: a second render record is refused and the key stays" do
      {:ok, run} =
        Run |> start() |> record_render(inputs(), context: %{paper: %{payload_hash_key: @key}})

      assert {:error, _} =
               record_render(run, inputs(), context: %{paper: %{payload_hash_key: @other_key}})

      assert Ash.get!(Run, run.id, authorize?: false).payload_hash_key == @key
    end

    test "no other action takes it from the context" do
      {:ok, run} =
        Run |> start() |> record_render(inputs(), context: %{paper: %{payload_hash_key: @key}})

      {:ok, read} =
        run
        |> Ash.Changeset.for_update(:record_read_back, %{read_back_status: :passed},
          context: %{paper: %{payload_hash_key: @other_key, clause_reasons: [%{"key" => "x"}]}}
        )
        |> Ash.update(authorize?: false)

      assert read.payload_hash_key == @key
      assert read.clause_reasons == []
      refute :payload_hash_key in Ash.Resource.Info.action(Run, :record_read_back).accept
      refute :payload_hash_key in Ash.Resource.Info.action(Run, :record_render_failure).accept
    end

    test "is never written by a failed render" do
      {:ok, failed} =
        Run
        |> start()
        |> Ash.Changeset.for_update(:record_render_failure, %{problems: [%{"kind" => "x"}]},
          context: %{paper: %{payload_hash_key: @key}}
        )
        |> Ash.update(authorize?: false)

      assert failed.payload_hash_key == nil
    end
  end

  describe "on a host that seals" do
    test "the key from the context reaches the host's sealer as an argument" do
      action = Ash.Resource.Info.action(SealedRun, :record_render)
      assert Enum.any?(action.arguments, &(&1.name == :payload_hash_key and &1.sensitive?))
      refute :payload_hash_key in action.accept

      changeset =
        SealedRun
        |> start()
        |> Ash.Changeset.for_update(:record_render, inputs(),
          context: %{paper: %{payload_hash_key: @key}}
        )

      assert changeset.context[:sealed_by_host]
      assert :error = Ash.Changeset.fetch_argument(changeset, :payload_hash_key)

      {:ok, run} = Ash.update(changeset, authorize?: false)
      stored = Ash.get!(SealedRun, run.id, authorize?: false)

      assert "sealed:" <> _ = Base.decode64!(stored.encrypted_payload_hash_key)
      refute stored.encrypted_payload_hash_key =~ @key
      assert Ash.load!(stored, :payload_hash_key, authorize?: false).payload_hash_key == @key
    end

    test "a key passed as an input is sealed the same way" do
      {:ok, run} = SealedRun |> start() |> record_render(inputs(%{payload_hash_key: @key}))

      stored = Ash.get!(SealedRun, run.id, authorize?: false)
      assert "sealed:" <> _ = Base.decode64!(stored.encrypted_payload_hash_key)
      assert Ash.load!(stored, :payload_hash_key, authorize?: false).payload_hash_key == @key
    end

    test "payload and facts are sealed beside it and the reasons are stored plain" do
      {:ok, run} =
        SealedRun
        |> start()
        |> record_render(inputs(%{document_version_id: @version_id}),
          context: %{paper: %{payload_hash_key: @key, clause_reasons: @reasons}}
        )

      stored = Ash.get!(SealedRun, run.id, authorize?: false)
      assert is_binary(stored.encrypted_payload) and is_binary(stored.encrypted_facts)
      assert stored.clause_reasons == @reasons
      assert stored.document_version_id == @version_id

      loaded = Ash.load!(stored, [:payload, :facts], authorize?: false)
      assert loaded.payload == %{"title" => "t"}
      assert loaded.facts == %{"fee" => "1"}
    end

    test "no key leaves the sealed column empty" do
      {:ok, run} = SealedRun |> start() |> record_render(inputs())
      assert Ash.get!(SealedRun, run.id, authorize?: false).encrypted_payload_hash_key == nil
    end
  end

  describe "problem/1" do
    @table [
      {{:mismatch, :field, :fee}, %{"kind" => "mismatch", "where" => "field", "key" => "fee"}},
      {{:unmeasured, :table, "rows"},
       %{"kind" => "unmeasured", "where" => "table", "key" => "rows"}},
      {{:missing_decision_input, "late_fee", "region"},
       %{"kind" => "missing_decision_input", "key" => "late_fee", "detail" => "region"}},
      {{:clause_undecided, "late_fee"}, %{"kind" => "clause_undecided", "key" => "late_fee"}},
      {{:clause_decision_failed, "late_fee", :boom},
       %{"kind" => "clause_decision_failed", "key" => "late_fee", "detail" => ":boom"}},
      {{:clause_reason_missing, "late_fee"},
       %{"kind" => "clause_reason_missing", "key" => "late_fee"}},
      {{:clause_not_pinned, "late_fee", :fr},
       %{"kind" => "clause_not_pinned", "key" => "late_fee", "detail" => "fr"}},
      {{:binding_stale, [%{"kind" => "theme"}]},
       %{"kind" => "binding_stale", "detail" => ~s(the binding's pins: [%{"kind" => "theme"}])}},
      {{:unfilled_holes, "late_fee", [:fee]},
       %{"kind" => "unfilled_holes", "key" => "late_fee", "detail" => "[:fee]"}},
      {{:missing_fact, %{"question" => "q", "rule" => "r"}},
       %{"kind" => "missing_fact", "question" => "q", "rule" => "r"}},
      {{:requirement_failed, %{"message" => "m"}},
       %{"kind" => "requirement_failed", "message" => "m"}},
      {{:requirement_undecided, ["a", :b]},
       %{"kind" => "requirement_undecided", "detail" => "a, b"}},
      {{:requirement_undecided, []}, %{"kind" => "requirement_undecided", "detail" => ""}},
      {{:requirement_error, "bad"}, %{"kind" => "requirement_error", "detail" => "bad"}},
      {:timeout, %{"kind" => "timeout"}},
      {:nothing_to_check, %{"kind" => "nothing_to_check"}},
      {{:too_many_pages, 3, 2},
       %{"kind" => "too_many_pages", "detail" => "{:too_many_pages, 3, 2}"}},
      {{:unreadable, :enoent}, %{"kind" => "unreadable", "detail" => "{:unreadable, :enoent}"}}
    ]

    test "maps each known term" do
      for {term, expected} <- @table do
        assert Fragment.problem(term) == expected, "for #{inspect(term)}"
      end
    end

    test "an unknown term is still a problem with a kind, never a raise" do
      pid = self()
      ref = make_ref()

      unknown = [
        "boom",
        nil,
        42,
        [1, 2],
        %{"a" => 1},
        %RuntimeError{message: "x"},
        {},
        {{:nested}, 1},
        {:mismatch, {:odd}, [:key]},
        {:missing_fact, "not a map"},
        {:requirement_failed, %RuntimeError{message: "x"}},
        {:requirement_undecided, [:a | :b]},
        {:missing_decision_input, {:k}, pid},
        {:missing_fact, %{{:tuple, :key} => ref}},
        fn -> :ok end
      ]

      for term <- unknown do
        problem = Fragment.problem(term)
        assert is_binary(problem["kind"]) and problem["kind"] != "", "for #{inspect(term)}"
        assert {:ok, _} = Jason.encode(problem), "for #{inspect(term)}"
      end

      assert Fragment.problem("boom") == %{"kind" => "render_error", "detail" => ~s("boom")}
      assert Fragment.problem(nil) == %{"kind" => "render_error", "detail" => "nil"}
      assert %{"kind" => "missing_fact", "detail" => _} = Fragment.problem({:missing_fact, "x"})
    end

    test "a stored problem survives a JSON round trip" do
      for {term, _expected} <- @table do
        assert {:ok, json} = Jason.encode(Fragment.problem(term))
        assert %{"kind" => _} = Jason.decode!(json)
      end
    end

    test "the run stores what it returns" do
      problems = Enum.map([:timeout, {:mismatch, :field, :fee}, "boom"], &Fragment.problem/1)

      {:ok, failed} =
        Run
        |> start()
        |> Ash.Changeset.for_update(:record_render_failure, %{problems: problems})
        |> Ash.update(authorize?: false)

      assert failed.render_status == :failed
      assert failed.problems == problems
    end
  end
end
