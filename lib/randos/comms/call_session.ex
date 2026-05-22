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

  @default_call_duration_seconds 300
  @extension_duration_seconds 300
  @max_call_duration_seconds 1_800
  @max_extension_count 5
  @extension_response_timeout_seconds 20
  @supported_language_codes ConversationLanguages.codes()
  @ended_reasons [
    :canceled,
    :completed,
    :extension_declined,
    :extension_timeout,
    :hangup,
    :disconnected,
    :connection_failed,
    :peer_disconnected,
    :max_duration_reached
  ]

  def default_call_duration_seconds, do: @default_call_duration_seconds
  def extension_duration_seconds, do: @extension_duration_seconds
  def max_call_duration_seconds, do: @max_call_duration_seconds
  def max_extension_count, do: @max_extension_count
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
      change &__MODULE__.ensure_extension_available/2
      change transition_state(:active)
      change increment(:extension_count)
    end

    update :end_call do
      require_atomic? false

      argument :ended_reason, :atom do
        allow_nil? false
        constraints one_of: @ended_reasons
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
    validate compare(:extension_count, less_than_or_equal_to: @max_extension_count)
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
      constraints one_of: @ended_reasons
    end

    attribute :default_call_duration_seconds, :integer do
      allow_nil? false
      public? true
      default @default_call_duration_seconds
    end

    attribute :extension_duration_seconds, :integer do
      allow_nil? false
      public? true
      default @extension_duration_seconds
    end

    attribute :max_duration_seconds, :integer do
      allow_nil? false
      public? true
      default @max_call_duration_seconds
    end

    attribute :max_extension_count, :integer do
      allow_nil? false
      public? true
      default @max_extension_count
    end

    attribute :extension_count, :integer do
      allow_nil? false
      public? true
      default 0
      constraints min: 0
    end
  end

  @doc false
  def ensure_extension_available(changeset, _context) do
    if Ash.Changeset.get_attribute(changeset, :extension_count) >= @max_extension_count do
      Ash.Changeset.add_error(
        changeset,
        field: :extension_count,
        message: "has reached the maximum extension count"
      )
    else
      changeset
    end
  end
end
