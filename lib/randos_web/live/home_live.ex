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
  alias RandosWeb.ParticipantErrors
  alias RandosWeb.ParticipantShell

  import RandosWeb.HomeComponents

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "randos")
      |> assign(:ice_servers, nil)
      |> assign(:voice_processor, RandosWeb.VoiceProcessor.configured())
      |> assign(:call_id, nil)

    case connected?(socket) && resume(socket) do
      {:ok, socket} -> {:ok, socket}
      _fresh -> {:ok, start_fresh(socket, default_preferences(socket))}
    end
  end

  # A page whose connection dropped mid-call reconnects with the resume
  # ticket it was given (held in the page's memory, sent as a connect
  # param) and takes its place in the call again; the page's WebRTC call
  # kept running meanwhile.
  defp resume(socket) do
    with ticket when is_binary(ticket) <- get_connect_params(socket)["resume_ticket"],
         {:ok, participant, fresh} <- ParticipantShell.resume(ticket) do
      Phoenix.PubSub.subscribe(Randos.PubSub, participant.topic)

      preferences = %{
        "speaking_language" => participant.preferences.speaks,
        "hearing_languages" => participant.preferences.hears,
        "adult_acknowledgment" => "true"
      }

      {:ok,
       socket
       |> assign(:preferences, preferences)
       |> assign_form(preferences)
       |> assign(:ice_servers, Jason.encode!(RandosWeb.IceServers.list()))
       |> assign_participant(participant)
       |> push_event("randos:resume_ticket", %{ticket: fresh})}
    end
  end

  defp start_fresh(socket, preferences) do
    participant = Participant.new(participant_preferences(preferences))

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Randos.PubSub, participant.topic)
    end

    socket
    |> assign(:preferences, preferences)
    |> assign_form(preferences)
    |> assign_participant(participant)
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
  # The WebRTC hook sends a reason when it can't carry the call (mic denied…).
  def handle_event("end_call", %{"reason" => reason}, socket) when is_binary(reason) do
    case Participant.cast_end_call_reason(reason) do
      {:ok, reason} -> {:noreply, run(socket, {:end_call, reason})}
      :error -> {:noreply, run(socket, :end_call)}
    end
  end

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

  def handle_info({:resume_ticket, _pid, _ticket} = event, socket),
    do: {:noreply, run(socket, event)}

  def handle_info({:resumed_elsewhere, _pid} = event, socket), do: {:noreply, run(socket, event)}

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

  defp deliver({:resume_ticket, ticket}, socket),
    do: push_event(socket, "randos:resume_ticket", %{ticket: ticket})

  # Another connection took this participant's seat (this one is a ghost of
  # a dropped connection): let go of it and start over.
  defp deliver(:detach, socket) do
    Phoenix.PubSub.unsubscribe(Randos.PubSub, socket.assigns.participant.topic)
    start_fresh(socket, socket.assigns.preferences)
  end

  defp deliver({:ice_servers, servers}, socket),
    do: assign(socket, :ice_servers, servers && Jason.encode!(servers))

  # Templates read these flat assigns, derived from the participant.
  defp assign_participant(socket, %Participant{} = participant) do
    socket
    |> assign(:participant, participant)
    |> assign(:ui_state, participant.status)
    |> assign(:webrtc_role, participant.webrtc_role)
    |> assign(:call_id, participant.call && participant.call.id)
    |> assign(:call_status, participant.call && participant.call.status)
    |> assign(:call_deadline_unix_ms, participant.call && participant.call.call_deadline_unix_ms)
    |> assign(:ice_transport_policy, participant.call && participant.call.ice_transport_policy)
    |> assign(
      :peer_language,
      participant.call && ParticipantShell.peer_speaks(participant.call, participant.id)
    )
    |> assign(:matchmaking_error, ParticipantErrors.message(participant.error))
    |> assign(
      :peer_reconnecting,
      participant.call != nil and
        ParticipantShell.peer_reconnecting?(participant.call, participant.id)
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} in_call={@call_status in [:connecting, :active, :extension_pending]}>
      <div class="min-h-[calc(100vh-5rem)] overflow-x-hidden bg-stone-50 text-stone-950">
        <section class="mx-auto grid w-full max-w-6xl gap-6 px-4 py-5 sm:gap-10 sm:px-8 sm:py-8 lg:grid-cols-[minmax(0,0.92fr)_minmax(420px,1.08fr)] lg:py-14">
          <.hero_panel ui_state={@ui_state} />
          <.conversation_card
            ui_state={@ui_state}
            call_id={@call_id}
            call_status={@call_status}
            call_deadline_unix_ms={@call_deadline_unix_ms}
            webrtc_role={@webrtc_role}
            ice_servers={@ice_servers}
            ice_transport_policy={@ice_transport_policy}
            voice_processor={@voice_processor}
            preferences={@preferences}
            peer_language={@peer_language}
            peer_reconnecting={@peer_reconnecting}
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

    # The speaking language starts checked among the hearing languages (the
    # person can uncheck it): two people who share a language can talk.
    # Only here: after the form first appears, the hearing choices are the
    # person's alone, whatever they speak.
    %{
      "speaking_language" => speaking_language,
      "hearing_languages" => [speaking_language],
      "adult_acknowledgment" => "false"
    }
  end

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
      Map.take(params, ["speaking_language", "hearing_languages", "adult_acknowledgment"])
    )
    |> Map.update("adult_acknowledgment", "false", &normalize_checkbox/1)
    |> Map.update("hearing_languages", [], &supported_languages/1)
  end

  # The form sends a "" placeholder so that unchecking everything still
  # submits the field; keep only supported codes (the matchmaker checks too).
  defp supported_languages(codes) when is_list(codes),
    do: codes |> Enum.filter(&ConversationLanguages.supported?/1) |> Enum.uniq()

  defp supported_languages(_codes), do: []

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
      hears: preferences["hearing_languages"],
      adult_acknowledged?: acknowledged?(preferences),
      # The browser always brings WebRTC audio.
      audio?: true
    }
  end
end
