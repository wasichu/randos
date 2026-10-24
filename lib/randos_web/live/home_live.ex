defmodule RandosWeb.HomeLive do
  @moduledoc """
  The web shell around `Randos.Participant`.

  Browser events and PubSub messages become participant events; the effects
  the participant returns are run here (matchmaker, call coordinator,
  `push_event`). This module owns only web concerns: the form, error copy,
  and rendering.

  `/join` (the `:join` action) is where an invitation link lands: the 18+
  acknowledgement and "Join the call". The link's token is in the URL
  fragment, which never reaches the server; the `JoinLink` hook adds it to
  the form only when it's submitted, so a page that merely loads (a link
  preview's bot, say) claims nothing. Once in the call, the page moves to
  `/`, so the used link isn't offered again.
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
      # On /join: whether the link has a token at all (the hook says).
      |> assign(:join_link, :unknown)
      # Whether this page's JavaScript can restart ICE (obligation 10): a
      # connect param, so it's the code the page actually loaded.
      |> assign(
        :ice_restart?,
        connected?(socket) and get_connect_params(socket)["ice_restart"] == true
      )

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
         {:ok, participant, fresh, ice_servers} <- ParticipantShell.resume(ticket) do
      Phoenix.PubSub.subscribe(Randos.PubSub, participant.topic)

      # An invitation's joiner never chose languages (the call's record has
      # the creator's), so the form starts from the defaults instead.
      preferences =
        if participant.call_kind == :invitation and participant.webrtc_role == :answerer,
          do: Map.put(default_preferences(socket), "adult_acknowledgment", "true"),
          else: %{
            "speaking_language" => participant.preferences.speaks,
            "hearing_languages" => participant.preferences.hears,
            "adult_acknowledgment" => "true"
          }

      {:ok,
       socket
       |> assign(:preferences, preferences)
       |> assign_form(preferences)
       |> assign(:ice_servers, Jason.encode!(ice_servers))
       |> assign_participant(participant)
       |> push_event("randos:resume_ticket", %{ticket: fresh})}
    end
  end

  defp start_fresh(socket, preferences) do
    participant =
      Participant.new(participant_preferences(preferences, socket.assigns.ice_restart?))

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Randos.PubSub, participant.topic)
    end

    socket
    |> assign(:preferences, preferences)
    |> assign_form(preferences)
    |> assign_participant(participant)
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

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

  # The form's choices are already here (update_preferences on every change).
  def handle_event("invite", _params, socket),
    do: {:noreply, run(socket, {:invite, participant_preferences(socket)})}

  def handle_event("cancel_invitation", _params, socket),
    do: {:noreply, run(socket, :cancel_invitation)}

  # The hook says whether the fragment holds a token; never the token itself.
  def handle_event("join_link", %{"has_token" => has_token}, socket),
    do:
      {:noreply, assign(socket, :join_link, if(has_token == true, do: :present, else: :missing))}

  def handle_event("accept_invitation", %{"token" => token} = params, socket)
      when is_binary(token) and byte_size(token) <= 64 do
    socket = put_preferences(socket, Map.get(params, "conversation", %{}))

    capabilities = %{
      adult_acknowledged?: acknowledged?(socket.assigns.preferences),
      audio?: true,
      ice_restart?: socket.assigns.ice_restart?
    }

    socket = run(socket, {:accept_invitation, token, capabilities})

    if socket.assigns.ui_state == :idle,
      do: {:noreply, socket},
      else: {:noreply, push_patch(socket, to: ~p"/")}
  end

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
  def handle_info(:invitation_expired, socket), do: {:noreply, run(socket, :invitation_expired)}

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
    |> assign(:matchmaking_error, ParticipantErrors.message(participant.error))
    |> assign(:notice, ParticipantErrors.notice(participant.notice))
    # On /join: the link can't be used from here (any more), so no form.
    |> assign(:link_failed, participant.error in [:invitation_invalid, :audio_mismatch])
    |> assign(:invitation, ParticipantShell.client_invitation(participant.invitation))
    |> assign(:call_kind, participant.call_kind)
    |> assign(call_assigns(participant.call, participant.id))
  end

  defp call_assigns(nil, _participant_id) do
    [
      call_id: nil,
      call_status: nil,
      call_deadline_unix_ms: nil,
      ice_transport_policy: nil,
      ice_generation: nil,
      ice_restart: false,
      recovering: false,
      peer_languages: [],
      peer_reconnecting: false,
      agreed_to_continue: false
    ]
  end

  defp call_assigns(call, participant_id) do
    [
      call_id: call.id,
      call_status: call.status,
      call_deadline_unix_ms: call.call_deadline_unix_ms,
      ice_transport_policy: call.ice_transport_policy,
      ice_generation: call.ice_generation,
      ice_restart: call.ice_restart?,
      recovering: call.recovering,
      peer_languages: ParticipantShell.peer_speaks_any(call, participant_id),
      peer_reconnecting: ParticipantShell.peer_reconnecting?(call, participant_id),
      agreed_to_continue: ParticipantShell.agreed_to_continue?(call, participant_id)
    ]
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} in_call={@call_status in [:connecting, :active, :extension_pending]}>
      <div class="min-h-[calc(100vh-5rem)] overflow-x-hidden bg-stone-50 text-stone-950">
        <section class="mx-auto grid w-full max-w-6xl gap-6 px-4 py-5 sm:gap-10 sm:px-8 sm:py-8 lg:grid-cols-[minmax(0,0.92fr)_minmax(420px,1.08fr)] lg:py-14">
          <.hero_panel
            ui_state={@ui_state}
            flow={progress_flow(@live_action, @ui_state, @call_kind, @webrtc_role)}
          />
          <.conversation_card
            ui_state={@ui_state}
            call_id={@call_id}
            call_status={@call_status}
            call_deadline_unix_ms={@call_deadline_unix_ms}
            webrtc_role={@webrtc_role}
            ice_servers={@ice_servers}
            ice_transport_policy={@ice_transport_policy}
            ice_generation={@ice_generation}
            ice_restart={@ice_restart}
            voice_processor={@voice_processor}
            preferences={@preferences}
            peer_languages={@peer_languages}
            live_action={@live_action}
            join_link={@join_link}
            link_failed={@link_failed}
            invitation={@invitation}
            call_kind={@call_kind}
            peer_reconnecting={@peer_reconnecting}
            recovering={@recovering}
            agreed_to_continue={@agreed_to_continue}
            form={@form}
            matchmaking_error={@matchmaking_error}
            notice={@notice}
          />
        </section>
      </div>
    </Layouts.app>
    """
  end

  # Which steps the progress list shows: an invitation has its own, the
  # creator's (they invited; they offer in the call) and the joiner's.
  defp progress_flow(:join, :idle, _kind, _role), do: :join
  defp progress_flow(_action, :inviting, _kind, _role), do: :invite
  defp progress_flow(_action, _state, :invitation, :offerer), do: :invite
  defp progress_flow(_action, _state, :invitation, _role), do: :join
  defp progress_flow(_action, _state, _kind, _role), do: :random

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
    do: participant_preferences(socket.assigns.preferences, socket.assigns.ice_restart?)

  defp participant_preferences(preferences, ice_restart?) do
    %{
      speaks: preferences["speaking_language"],
      hears: preferences["hearing_languages"],
      adult_acknowledged?: acknowledged?(preferences),
      # The browser always brings WebRTC audio.
      audio?: true,
      ice_restart?: ice_restart?
    }
  end
end
