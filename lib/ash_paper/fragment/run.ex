defmodule AshPaper.Fragment.Run do
  @moduledoc """
  One attempt to produce a document, with two independent status axes. A host instantiates
  this on its own base resource. A read-back that never ran stays `:not_run`, which is visible
  and is not a pass.

  `payload` and `facts` are frozen at render time. The host seals them under its erasure scope.
  """

  use Spark.Dsl.Fragment, of: Ash.Resource

  attributes do
    uuid_primary_key :id

    attribute :document_kind, :string, allow_nil?: false, public?: true

    attribute :render_status, :atom,
      allow_nil?: false,
      default: :pending,
      public?: true,
      constraints: [one_of: [:pending, :rendered, :failed]]

    attribute :read_back_status, :atom,
      allow_nil?: false,
      default: :not_run,
      public?: true,
      constraints: [one_of: [:not_run, :passed, :failed, :unmeasured]]

    attribute :snapshot, :map, public?: true
    attribute :output_digest, :string, public?: true, constraints: [match: ~r/\A[0-9a-f]{64}\z/]
    attribute :problems, {:array, :map}, allow_nil?: false, default: [], public?: true
    attribute :payload, :map, sensitive?: true, public?: true
    attribute :facts, :map, sensitive?: true, public?: true
  end

  actions do
    defaults [:read]

    create :start do
      accept [:document_kind]
    end

    update :record_render do
      accept [:snapshot, :output_digest, :payload, :facts]
      validate {AshPaper.Fragment.StoredValue, attribute: :render_status, value: :pending}
      validate present([:snapshot, :output_digest, :payload, :facts])
      change set_attribute(:render_status, :rendered)
    end

    update :record_render_failure do
      accept [:problems]
      validate {AshPaper.Fragment.StoredValue, attribute: :render_status, value: :pending}
      change set_attribute(:render_status, :failed)
    end

    update :record_read_back do
      accept [:read_back_status, :problems]
      validate {AshPaper.Fragment.StoredValue, attribute: :render_status, value: :rendered}
      validate {AshPaper.Fragment.StoredValue, attribute: :read_back_status, value: :not_run}
      validate one_of(:read_back_status, [:passed, :failed, :unmeasured])
    end
  end
end
