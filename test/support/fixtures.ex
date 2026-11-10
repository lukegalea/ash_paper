defmodule AshPaper.Test.Letter do
  @moduledoc false
  use AshPaper.Layout, key: :letter, version: 1, path: Path.expand("letter.typ", __DIR__)
end

defmodule AshPaper.Test.NoticeSchema do
  @moduledoc false
  use AshPaper.Schema

  paper do
    key :notice
    version 1
    field :vendor, :text, label: [en: "Vendor", fr: "Fournisseur"]
    field :property, :text, label: [en: "Property", fr: "Propriété"]
    field :renews_on, :date, label: [en: "Renews on", fr: "Renouvellement le"]
    field :fee, :money, label: [en: "Fee", fr: "Frais"]
    field :term_months, :integer, label: [en: "Term in months", fr: "Durée en mois"]
    field :note, :text, label: "Note", required?: false
  end
end

defmodule AshPaper.Test.SummarySchema do
  @moduledoc false
  use AshPaper.Schema

  paper do
    key :summary
    version 1
    field :year, :text, label: "Year"
    field :income, :money, currency: [:currency], label: "Income"

    table :lines do
      field :account, :text, label: "Account"
      field :amount, :money, label: "Amount"
    end
  end
end

defmodule AshPaper.Test.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule AshPaper.Test.Vendor do
  @moduledoc false
  use Ash.Resource, domain: AshPaper.Test.Domain, data_layer: Ash.DataLayer.Ets

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true
  end

  relationships do
    has_many :contracts, AshPaper.Test.Contract
  end

  actions do
    defaults [:read, create: :*]
  end
end

defmodule AshPaper.Test.Contract do
  @moduledoc false
  use Ash.Resource, domain: AshPaper.Test.Domain, data_layer: Ash.DataLayer.Ets

  attributes do
    uuid_primary_key :id
    attribute :title, :string, public?: true
  end

  relationships do
    belongs_to :vendor, AshPaper.Test.Vendor, public?: true
  end

  actions do
    defaults [:read, create: :*]
  end
end

defmodule AshPaper.Test.ContractSchema do
  @moduledoc false
  use AshPaper.Schema

  paper do
    key :contract
    version 1
    resource AshPaper.Test.Contract
    field :title, :text, label: "Title"
    field :vendor, :text, path: [:vendor, :name], label: "Vendor"
  end
end

defmodule AshPaper.Test.Run do
  @moduledoc false
  use Ash.Resource,
    domain: AshPaper.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    fragments: [AshPaper.Fragment.Run]
end

defmodule AshPaper.Test.Build do
  @moduledoc false
  alias AshPaper.{Payload, Render, Theme}

  def theme(font \\ "Carlito", accent \\ "#1f3a5f") do
    {:ok, theme} =
      Theme.new(%{
        key: "acme",
        version: 1,
        body_font: font,
        heading_font: font,
        body_size: 11,
        margin_x: 72,
        margin_y: 72,
        paper: "us-letter",
        accent: accent
      })

    theme
  end

  def notice(overrides \\ %{}) do
    Map.merge(
      %{
        vendor: "Northwind Elevators",
        property: "12 Rue Sainte-Catherine",
        renews_on: ~D[2027-03-01],
        fee: Money.new!(:CAD, "4575.50"),
        term_months: 12,
        note: nil
      },
      overrides
    )
  end

  def summary(rows \\ 3) do
    %{
      year: "2026",
      income: Decimal.new("120000.25"),
      currency: "USD",
      lines:
        for i <- 1..rows do
          %{
            account: "Account #{i}",
            amount: Money.new!(if(rem(i, 2) == 0, do: :EUR, else: :CAD), "#{i}000.10")
          }
        end
    }
  end

  def payload(schema \\ AshPaper.Test.NoticeSchema, source \\ notice(), locale \\ :en) do
    {:ok, payload} = Payload.build(schema, source, title: "Renewal notice", locale: locale)
    payload
  end

  def render(payload, theme, clauses \\ [], opts \\ []) do
    Render.render(
      AshPaper.Test.Letter,
      theme,
      payload,
      clauses,
      Keyword.merge([max_pages: 20, timeout_ms: 30_000, isolate?: false], opts)
    )
  end
end
