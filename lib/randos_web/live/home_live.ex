defmodule RandosWeb.HomeLive do
  @moduledoc """
  The web shell around `Randos.Participant`.

  Browser events and PubSub messages become participant events; the effects
  the participant returns are run here (matchmaker, call coordinator,
  `push_event`). This module owns only web concerns: the form, error copy,
  and rendering.
  """
  use RandosWeb, :live_view

  alias Randos.ConversationLanguages
  alias Randos.Matchmaking.Matchmaker
  alias Randos.Participant
  alias RandosWeb.ParticipantShell

  import RandosWeb.HomeComponents

  @impl true
  def mount(_params, _session, socket) do
    preferences = default_preferences(socket)
    participant = Participant.new(participant_preferences(preferences))

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Randos.PubSub, participant.topic)
    end

    {:ok,
     socket
     |> assign(:page_title, gettext("Randos"))
     |> assign(:preferences, preferences)
     |> assign_form(preferences)
     |> assign(:ice_servers, nil)
     |> assign_participant(participant)}
  end

  @impl true
  def handle_event("update_preferences", %{"conversation" => params}, socket) do
    socket = put_preferences(socket, params)
    {:noreply, run(socket, {:update_preferences, participant_preferences(socket)})}
  end

  def handle_event("find", %{"conversation" => params}, socket) do
    socket = put_preferences(socket, params)
    {:noreply, run(socket, {:find, participant_preferences(socket)})}
  end

  def handle_event("cancel_search", _params, socket), do: {:noreply, run(socket, :cancel_search)}
  def handle_event("end_call", _params, socket), do: {:noreply, run(socket, :end_call)}
  def handle_event("next_rando", _params, socket), do: {:noreply, run(socket, :next)}

  def handle_event("extension_vote", %{"vote" => vote}, socket) do
    vote = if vote == "continue", do: :continue, else: :end
    {:noreply, run(socket, {:vote, vote})}
  end

  def handle_event("signal", %{"type" => type} = params, socket) do
    {:noreply, run(socket, {:client_signal, type, Map.get(params, "payload", %{})})}
  end

  @impl true
  def handle_info({:call_updated, _call} = event, socket), do: {:noreply, run(socket, event)}
  def handle_info({:signaling, _message} = event, socket), do: {:noreply, run(socket, event)}

  @impl true
  def terminate(_reason, _socket) do
    Matchmaker.leave(self())
    :ok
  end

  ## Running the participant core (see RandosWeb.ParticipantShell)

  defp run(socket, event) do
    {participant, client_effects} = ParticipantShell.run(socket.assigns.participant, event)
    Enum.reduce(client_effects, assign_participant(socket, participant), &deliver/2)
  end

  defp deliver({:push_signal, message}, socket), do: push_event(socket, "randos:signal", message)

  defp deliver({:ice_servers, servers}, socket),
    do: assign(socket, :ice_servers, servers && Jason.encode!(servers))

  # Templates read these flat assigns, derived from the participant.
  defp assign_participant(socket, %Participant{} = participant) do
    socket
    |> assign(:participant, participant)
    |> assign(:ui_state, participant.status)
    |> assign(:webrtc_role, participant.webrtc_role)
    |> assign(:call_status, participant.call && participant.call.status)
    |> assign(:call_deadline_unix_ms, participant.call && participant.call.call_deadline_unix_ms)
    |> assign(:matchmaking_error, error_message(participant.error))
  end

  defp error_message(nil), do: nil

  defp error_message(:adult_terms_required),
    do: gettext("Accept the 18+ acknowledgment before looking for a rando.")

  defp error_message(:unsupported_language),
    do: gettext("Choose supported conversation languages.")

  defp error_message(:call_start_failed),
    do: gettext("We couldn't start that call. Please try again.")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="min-h-[calc(100vh-5rem)] overflow-x-hidden bg-stone-50 text-stone-950">
        <section class="mx-auto grid w-full max-w-6xl gap-6 px-4 py-5 sm:gap-10 sm:px-8 sm:py-8 lg:grid-cols-[minmax(0,0.92fr)_minmax(420px,1.08fr)] lg:py-14">
          <.hero_panel ui_state={@ui_state} />
          <.conversation_card
            ui_state={@ui_state}
            call_status={@call_status}
            call_deadline_unix_ms={@call_deadline_unix_ms}
            webrtc_role={@webrtc_role}
            ice_servers={@ice_servers}
            preferences={@preferences}
            form={@form}
            matchmaking_error={@matchmaking_error}
          />
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp default_preferences(socket) do
    speaking_language = browser_locale_language(socket)

    %{
      "speaking_language" => speaking_language,
      "listening_language" => default_listening_language(speaking_language),
      "adult_acknowledgment" => "false"
    }
  end

  defp default_listening_language("en"), do: "es"
  defp default_listening_language(_speaking_language), do: "en"

  defp browser_locale_language(socket) do
    locale =
      if connected?(socket) do
        socket
        |> get_connect_params()
        |> Map.get("browser_locale")
      end

    ConversationLanguages.code_from_locale(locale)
  end

  defp normalize_preferences(params, current) do
    current
    |> Map.merge(
      Map.take(params, ["speaking_language", "listening_language", "adult_acknowledgment"])
    )
    |> Map.update("adult_acknowledgment", "false", &normalize_checkbox/1)
  end

  defp normalize_checkbox(true), do: "true"
  defp normalize_checkbox("true"), do: "true"
  defp normalize_checkbox(_value), do: "false"

  defp assign_form(socket, preferences) do
    assign(socket, :form, to_form(preferences, as: :conversation))
  end

  defp put_preferences(socket, params) do
    preferences = normalize_preferences(params, socket.assigns.preferences)

    socket
    |> assign(:preferences, preferences)
    |> assign_form(preferences)
  end

  defp participant_preferences(%Phoenix.LiveView.Socket{} = socket),
    do: participant_preferences(socket.assigns.preferences)

  defp participant_preferences(preferences) do
    %{
      speaks: preferences["speaking_language"],
      listens: preferences["listening_language"],
      adult_acknowledged?: acknowledged?(preferences)
    }
  end
end
