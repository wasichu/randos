defmodule Randos.Comms.CallSession do
  @moduledoc """
  Domain lifecycle for a matched anonymous audio call.

  Realtime coordination, signaling, timers, extension votes, and audio transport
  belong to processes and browser code, not this resource.
  """

  use Ash.Resource,
    domain: Randos.Comms,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshStateMachine]

  alias Randos.ConversationLanguages

  @default_max_call_duration_seconds 300
  @extension_duration_seconds 300
  @extension_response_timeout_seconds 20
  @supported_language_codes ConversationLanguages.codes()

  def default_max_call_duration_seconds, do: @default_max_call_duration_seconds
  def extension_duration_seconds, do: @extension_duration_seconds
  def extension_response_timeout_seconds, do: @extension_response_timeout_seconds

  state_machine do
    initial_states [:connecting]
    default_initial_state :connecting
    state_attribute :status

    transitions do
      transition :mark_active, from: :connecting, to: :active
      transition :end_call, from: :connecting, to: :ended
      transition :mark_extension_pending, from: :active, to: :extension_pending
      transition :end_call, from: :active, to: :ended
      transition :extend_call, from: :extension_pending, to: :active
      transition :end_call, from: :extension_pending, to: :ended
    end
  end

  actions do
    defaults [:read]

    create :create_connecting_call do
      accept [
        :speaks_language_a,
        :listens_language_a,
        :speaks_language_b,
        :listens_language_b
      ]
    end

    update :mark_active do
      require_atomic? false
      change transition_state(:active)
      change set_attribute(:started_at, &DateTime.utc_now/0)
    end

    update :mark_extension_pending do
      require_atomic? false
      change transition_state(:extension_pending)
    end

    update :extend_call do
      require_atomic? false
      change transition_state(:active)
      change increment(:extension_count)
    end

    update :end_call do
      require_atomic? false

      argument :ended_reason, :atom do
        allow_nil? false
        constraints one_of: [:canceled, :completed, :declined_extension, :timeout, :hang_up]
      end

      change transition_state(:ended)
      change set_attribute(:ended_at, &DateTime.utc_now/0)
      change set_attribute(:ended_reason, arg(:ended_reason))
    end
  end

  validations do
    validate one_of(:speaks_language_a, @supported_language_codes)
    validate one_of(:listens_language_a, @supported_language_codes)
    validate one_of(:speaks_language_b, @supported_language_codes)
    validate one_of(:listens_language_b, @supported_language_codes)
  end

  attributes do
    uuid_primary_key :id

    attribute :speaks_language_a, :string do
      allow_nil? false
      public? true
    end

    attribute :listens_language_a, :string do
      allow_nil? false
      public? true
    end

    attribute :speaks_language_b, :string do
      allow_nil? false
      public? true
    end

    attribute :listens_language_b, :string do
      allow_nil? false
      public? true
    end

    attribute :started_at, :utc_datetime_usec do
      public? true
    end

    attribute :ended_at, :utc_datetime_usec do
      public? true
    end

    attribute :ended_reason, :atom do
      public? true
      constraints one_of: [:canceled, :completed, :declined_extension, :timeout, :hang_up]
    end

    attribute :max_duration_seconds, :integer do
      allow_nil? false
      public? true
      default @default_max_call_duration_seconds
    end

    attribute :extension_count, :integer do
      allow_nil? false
      public? true
      default 0
      constraints min: 0
    end
  end
end
