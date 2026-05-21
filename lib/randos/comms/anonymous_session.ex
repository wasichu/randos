defmodule Randos.Comms.AnonymousSession do
  @moduledoc """
  Anonymous app session preferences for a visitor.

  This is not a user account and intentionally has no profile, identity,
  contact, or social graph fields.
  """

  use Ash.Resource,
    domain: Randos.Comms,
    data_layer: Ash.DataLayer.Ets

  alias Randos.ConversationLanguages

  @supported_language_codes ConversationLanguages.codes()

  actions do
    defaults [:read]

    create :create_session do
      accept [:speaks_language, :listens_language, :accepted_adult_terms]
    end

    update :update_language_preferences do
      require_atomic? false
      accept [:speaks_language, :listens_language]
    end

    update :update_auto_requeue do
      require_atomic? false
      accept [:auto_requeue]
    end

    update :accept_adult_terms do
      require_atomic? false
      change set_attribute(:accepted_adult_terms, true)
    end
  end

  validations do
    validate one_of(:speaks_language, @supported_language_codes)
    validate one_of(:listens_language, @supported_language_codes)
  end

  attributes do
    uuid_primary_key :id

    attribute :speaks_language, :string do
      allow_nil? false
      public? true
    end

    attribute :listens_language, :string do
      allow_nil? false
      public? true
    end

    attribute :auto_requeue, :boolean do
      allow_nil? false
      public? true
      default false
    end

    attribute :accepted_adult_terms, :boolean do
      allow_nil? false
      public? true
      default false
    end

    create_timestamp :inserted_at do
      public? true
    end
  end

  @doc """
  Returns whether this anonymous session is allowed to enter matchmaking.
  """
  @spec matchmaking_ready?(t()) :: boolean()
  def matchmaking_ready?(%{__struct__: __MODULE__, accepted_adult_terms: true}), do: true
  def matchmaking_ready?(%{__struct__: __MODULE__}), do: false
end
