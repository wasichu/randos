defmodule RandosWeb.HomeLive do
  use RandosWeb, :live_view

  alias Randos.Calls.CallCoordinator
  alias Randos.ConversationFlow
  alias Randos.ConversationLanguages
  alias Randos.Matchmaking.Matchmaker
  alias Randos.Signaling

  @impl true
  def mount(_params, _session, socket) do
    preferences = default_preferences()
    participant_id = anonymous_participant_id()
    match_topic = "matchmaking:participant:#{participant_id}"

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Randos.PubSub, match_topic)
    end

    socket =
      socket
      |> assign(:page_title, gettext("Randos"))
      |> assign(:ui_state, :idle)
      |> assign(:preferences, preferences)
      |> assign(:stop_after_call?, true)
      |> assign(:participant_id, participant_id)
      |> assign(:match_topic, match_topic)
      |> assign(:matchmaking_error, nil)
      |> assign(:match, nil)
      |> assign(:match_role, nil)
      |> assign(:webrtc_role, nil)
      |> assign(:call_pid, nil)
      |> assign(:call_status, nil)
      |> assign(:call_ended_reason, nil)
      |> assign(:call_deadline_unix_ms, nil)
      |> assign(:extension_deadline_unix_ms, nil)
      |> assign(:extension_count, 0)
      |> assign_form(preferences)

    {:ok, socket}
  end

  @impl true
  def handle_event("update_preferences", %{"conversation" => params}, socket) do
    preferences = normalize_preferences(params, socket.assigns.preferences)

    {:noreply,
     socket
     |> assign(:preferences, preferences)
     |> assign_form(preferences)}
  end

  def handle_event("find", %{"conversation" => params}, socket) do
    preferences = normalize_preferences(params, socket.assigns.preferences)

    socket =
      socket
      |> assign(:preferences, preferences)
      |> assign(:matchmaking_error, nil)
      |> assign_form(preferences)

    if acknowledged?(preferences) do
      {:noreply, join_matchmaking(socket)}
    else
      {:noreply,
       assign(
         socket,
         :matchmaking_error,
         gettext("Accept the 18+ acknowledgment before looking for a rando.")
       )}
    end
  end

  def handle_event("transition", %{"to" => state}, socket) do
    to = parse_state(state)
    socket = maybe_leave_matchmaking(socket, to)

    {:noreply, transition(socket, to)}
  end

  def handle_event("hang_up", _params, socket) do
    socket = assign(socket, :stop_after_call?, true)
    hang_up_current_call(socket)

    {:noreply, socket}
  end

  def handle_event("next_rando", _params, socket) do
    socket = assign(socket, :stop_after_call?, false)
    hang_up_current_call(socket)

    {:noreply, socket}
  end

  def handle_event("end_call", _params, socket) do
    socket = assign(socket, :stop_after_call?, true)
    hang_up_current_call(socket)

    {:noreply, redirect(socket, to: ~p"/")}
  end

  def handle_event("extension_vote", %{"vote" => vote}, socket) do
    vote = if vote == "continue", do: :continue, else: :end
    socket = assign(socket, :stop_after_call?, vote == :end)

    if socket.assigns.call_pid do
      CallCoordinator.vote_extension(socket.assigns.call_pid, socket.assigns.participant_id, vote)
    end

    {:noreply, socket}
  end

  def handle_event("signal", %{"type" => type} = params, socket) do
    payload = Map.get(params, "payload", %{})
    socket = relay_client_signal(socket, type, payload)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:randos_match, match}, socket) do
    {:noreply, assign_match(socket, match)}
  end

  def handle_info({:mock_call_active, call}, socket) do
    {:noreply, assign_call_state(socket, call, :in_call)}
  end

  def handle_info({:mock_call_extension_pending, call}, socket) do
    {:noreply, assign_call_state(socket, call, :extension_pending)}
  end

  def handle_info({:mock_call_extended, call}, socket) do
    {:noreply, assign_call_state(socket, call, :in_call)}
  end

  def handle_info({:mock_call_ended, call}, socket) do
    {:noreply, finish_call(socket, call)}
  end

  def handle_info({:signaling, message}, socket) do
    {:noreply, push_event(socket, "randos:signal", encode_signal(message))}
  end

  @impl true
  def terminate(_reason, _socket) do
    Matchmaker.leave(self())
    :ok
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="min-h-[calc(100vh-5rem)] overflow-x-hidden bg-stone-50 text-stone-950">
        <section class="mx-auto grid w-full max-w-6xl gap-6 px-4 py-5 sm:gap-10 sm:px-8 sm:py-8 lg:grid-cols-[minmax(0,0.92fr)_minmax(420px,1.08fr)] lg:py-14">
          <div class="flex flex-col justify-between gap-10">
            <div>
              <h1 class="text-4xl font-semibold leading-none tracking-normal text-stone-950 sm:text-7xl">
                {gettext("Randos")}
              </h1>
              <p class="mt-4 max-w-xl text-lg leading-7 text-stone-700 sm:mt-6 sm:text-xl sm:leading-8">
                {gettext("Short anonymous conversations for language practice.")}
              </p>
              <p class="mt-3 text-base text-stone-500">
                {gettext("No accounts. No profiles. No video. No pressure.")}
              </p>
            </div>

            <div
              id="state-progress"
              class="grid grid-cols-1 gap-2 text-sm min-[420px]:grid-cols-2 sm:grid-cols-5 lg:grid-cols-1"
            >
              <div
                :for={state <- [:idle, :looking, :connecting, :in_call, :extension_pending]}
                id={"state-progress-#{state}"}
                class={[
                  "rounded-md border px-3 py-2 transition-colors duration-200 sm:px-4 sm:py-3",
                  progress_step_class(assigns, state)
                ]}
              >
                <p class="font-semibold">{state_label(state)}</p>
                <p class="mt-1 text-xs leading-5 opacity-75">{state_description(state)}</p>
              </div>
            </div>
          </div>

          <div class="grid min-w-0 grid-cols-1 overflow-hidden rounded-lg border border-stone-200 bg-white shadow-sm shadow-stone-200/70 sm:grid-cols-3">
            <.call_media_panel
              :if={@call_status in [:active, :extension_pending] && @webrtc_role}
              participant_id={@participant_id}
              webrtc_role={@webrtc_role}
            />

            <%= case @ui_state do %>
              <% :idle -> %>
                <div id="idle-panel" class="col-span-full p-5 sm:p-7">
                  <.form
                    for={@form}
                    id="conversation-form"
                    phx-change="update_preferences"
                    phx-submit="find"
                    class="space-y-5"
                  >
                    <div class="grid gap-4 sm:grid-cols-2">
                      <.input
                        field={@form[:speaking_language]}
                        type="select"
                        label={gettext("I will speak in")}
                        options={language_options()}
                        class="w-full rounded-md border border-stone-300 bg-white px-3 py-3 text-base text-stone-950 shadow-sm outline-none transition focus:border-teal-600 focus:ring-4 focus:ring-teal-100"
                      />
                      <.input
                        field={@form[:listening_language]}
                        type="select"
                        label={gettext("I want them to speak in")}
                        options={language_options()}
                        class="w-full rounded-md border border-stone-300 bg-white px-3 py-3 text-base text-stone-950 shadow-sm outline-none transition focus:border-teal-600 focus:ring-4 focus:ring-teal-100"
                      />
                    </div>

                    <div class="rounded-md border border-stone-200 bg-stone-50 px-4 py-4">
                      <.input
                        field={@form[:adult_acknowledgment]}
                        type="checkbox"
                        label={
                          gettext(
                            "I am 18 or older and understand that conversations are anonymous and unmoderated."
                          )
                        }
                        class="size-4 rounded border-stone-300 text-teal-700 focus:ring-teal-600"
                      />
                    </div>

                    <button
                      id="find-rando-button"
                      type="submit"
                      disabled={!acknowledged?(@preferences)}
                      class={[
                        "inline-flex w-full items-center justify-center gap-2 rounded-md px-5 py-3 text-base font-semibold transition duration-200",
                        acknowledged?(@preferences) &&
                          "bg-stone-950 text-white shadow-sm hover:-translate-y-0.5 hover:bg-teal-800 focus:outline-none focus:ring-4 focus:ring-teal-100",
                        !acknowledged?(@preferences) &&
                          "cursor-not-allowed bg-stone-200 text-stone-500"
                      ]}
                    >
                      <.icon name="hero-magnifying-glass" class="size-5" />
                      {gettext("Find a rando")}
                    </button>

                    <p
                      :if={@matchmaking_error}
                      id="matchmaking-error"
                      class="rounded-md border border-red-200 bg-red-50 px-4 py-3 text-sm font-medium text-red-700"
                    >
                      {@matchmaking_error}
                    </p>
                  </.form>
                </div>
              <% :looking -> %>
                <.searching_panel />
              <% :connecting -> %>
                <.connecting_panel
                  match_role={@match_role}
                  webrtc_role={@webrtc_role}
                  participant_id={@participant_id}
                />
              <% :in_call -> %>
                <.call_panel
                  preferences={@preferences}
                  participant_id={@participant_id}
                  webrtc_role={@webrtc_role}
                  language_name={&language_name/1}
                />
              <% :extension_pending -> %>
                <.extension_panel />
            <% end %>

            <.call_timer_panel
              :if={@ui_state == :in_call}
              call_status={@call_status}
              call_deadline_unix_ms={@call_deadline_unix_ms}
            />
            <.call_actions_panel :if={@ui_state == :in_call} />
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp searching_panel(assigns) do
    ~H"""
    <div id="looking-panel" class="col-span-full space-y-6 p-5 sm:p-7">
      <div>
        <p class="text-sm font-medium uppercase tracking-[0.16em] text-teal-700">
          {gettext("Looking")}
        </p>
        <h2 class="mt-3 text-3xl font-semibold tracking-normal text-stone-950">
          {gettext("Finding a rando")}
        </h2>
        <p id="looking-status" class="mt-3 leading-7 text-stone-600">
          {gettext("Waiting for someone with complementary language preferences.")}
        </p>
      </div>
      <div class="h-2 overflow-hidden rounded-full bg-stone-100">
        <div class="h-full w-1/2 rounded-full bg-teal-700 motion-safe:animate-pulse"></div>
      </div>
      <div class="grid gap-3">
        <button
          id="cancel-search-button"
          phx-click="transition"
          phx-value-to="idle"
          class="rounded-md border border-stone-300 px-5 py-3 font-semibold text-stone-700 transition hover:border-stone-950 hover:text-stone-950"
        >
          {gettext("Stop looking")}
        </button>
      </div>
    </div>
    """
  end

  attr :match_role, :atom, default: nil
  attr :webrtc_role, :atom, default: nil
  attr :participant_id, :string, required: true

  defp connecting_panel(assigns) do
    ~H"""
    <div
      id="connecting-panel"
      data-participant-id={@participant_id}
      data-webrtc-role={@webrtc_role}
      class="col-span-full space-y-6 p-5 sm:p-7"
    >
      <div>
        <p class="text-sm font-medium uppercase tracking-[0.16em] text-teal-700">
          {gettext("Connecting")}
        </p>
        <h2 class="mt-3 text-3xl font-semibold tracking-normal text-stone-950">
          {gettext("Preparing the call")}
        </h2>
        <p class="mt-3 leading-7 text-stone-600">
          {gettext("You have matched. Audio starts when the call opens.")}
        </p>
      </div>
      <div
        :if={@match_role && @webrtc_role}
        id="match-role-label"
        class="rounded-md border border-teal-100 bg-teal-50 px-4 py-3 text-sm font-medium text-teal-900"
      >
        {gettext("Match role:")} {role_label(@match_role)} · {webrtc_role_label(@webrtc_role)}
      </div>
      <div class="grid gap-3 sm:grid-cols-2">
        <button
          id="cancel-connection-button"
          phx-click="hang_up"
          class="rounded-md border border-stone-300 px-5 py-3 font-semibold text-stone-700 transition hover:border-stone-950 hover:text-stone-950"
        >
          {gettext("Cancel")}
        </button>
      </div>
    </div>
    """
  end

  attr :preferences, :map, required: true
  attr :participant_id, :string, required: true
  attr :webrtc_role, :atom, default: nil
  attr :language_name, :any, required: true

  defp call_panel(assigns) do
    ~H"""
    <div
      id="call-panel"
      data-participant-id={@participant_id}
      data-webrtc-role={@webrtc_role}
      class="order-1 col-span-full space-y-5 p-4 sm:space-y-6 sm:p-7"
    >
      <div>
        <h2 class="text-3xl font-semibold tracking-normal text-stone-950">
          {gettext("Current call")}
        </h2>
      </div>

      <div class="grid gap-3 sm:grid-cols-2 sm:gap-4">
        <.waveform
          id="local-waveform"
          label={gettext("You")}
          language={@language_name.(@preferences["speaking_language"])}
        />
        <.waveform
          id="remote-waveform"
          label={gettext("Your rando")}
          language={@language_name.(@preferences["listening_language"])}
        />
      </div>
    </div>
    """
  end

  defp call_actions_panel(assigns) do
    ~H"""
    <div class="order-3 col-span-full grid gap-2 border-t border-stone-200 px-4 py-3 sm:col-span-2 sm:grid-cols-2 sm:gap-3 sm:border-l sm:px-7">
      <button
        id="next-rando-button"
        phx-click="next_rando"
        class="inline-flex h-12 items-center justify-center rounded-md border border-stone-300 px-4 py-0 font-semibold leading-none text-stone-700 transition hover:border-stone-950 hover:text-stone-950"
      >
        {gettext("Next rando")}
      </button>
      <button
        id="end-call-button"
        phx-click="end_call"
        class="inline-flex h-12 items-center justify-center rounded-md border border-red-200 px-4 py-0 font-semibold leading-none text-red-700 transition hover:border-red-700 hover:bg-red-50"
      >
        {gettext("End")}
      </button>
    </div>
    """
  end

  attr :call_status, :atom, default: nil
  attr :call_deadline_unix_ms, :integer, default: nil

  defp call_timer_panel(assigns) do
    ~H"""
    <div class="order-2 col-span-full border-t border-stone-200 px-4 py-3 text-sm text-stone-500 sm:col-span-1 sm:px-7">
      <div
        :if={@call_status == :active && @call_deadline_unix_ms}
        id="call-countdown"
        phx-hook="CallCountdown"
        phx-update="ignore"
        data-deadline-unix-ms={@call_deadline_unix_ms}
        class="inline-flex items-center gap-2 font-medium text-stone-600"
      >
        <.icon name="hero-clock" class="size-4 text-teal-700" />
        <span id="call-countdown-value" data-countdown-value>--:-- remaining</span>
      </div>
    </div>
    """
  end

  attr :participant_id, :string, required: true
  attr :webrtc_role, :atom, required: true

  defp call_media_panel(assigns) do
    ~H"""
    <div
      id="webrtc-audio"
      phx-hook="WebRTCAudio"
      phx-update="ignore"
      data-participant-id={@participant_id}
      data-webrtc-role={@webrtc_role}
      data-webrtc-state="not_started"
      data-microphone-muted="false"
      class="contents"
    >
      <div class="order-2 col-span-full flex flex-col gap-2 border-t border-stone-200 px-4 py-3 text-sm text-stone-500 sm:col-span-2 sm:flex-row sm:items-center sm:justify-between sm:px-7">
        <div class="min-w-0">
          <p class="flex flex-wrap items-center gap-x-1 gap-y-0.5">
            <span>{gettext("Connection:")}</span>
            <span id="webrtc-state-label" data-webrtc-status>not started</span>
            <span id="microphone-status-label" data-microphone-status class="sr-only">
              {gettext("waiting for microphone")}
            </span>
            <span id="remote-audio-status-label" data-remote-audio-status class="sr-only">
              {gettext("waiting for remote audio")}
            </span>
          </p>
        </div>
      </div>

      <div class="order-3 col-span-full border-t border-stone-200 px-4 py-3 sm:col-span-1 sm:px-7">
        <button
          id="mute-button"
          type="button"
          data-webrtc-mute
          disabled
          aria-pressed="false"
          class="inline-flex h-12 w-full items-center justify-center gap-2 rounded-md border border-stone-300 px-4 py-0 font-semibold leading-none text-stone-700 transition hover:border-stone-950 hover:text-stone-950 disabled:cursor-not-allowed disabled:border-stone-200 disabled:text-stone-400"
        >
          <.icon name="hero-speaker-x-mark" class="size-5 shrink-0" />
          <span data-mute-label class="leading-none">{gettext("Mute")}</span>
        </button>
      </div>

      <audio
        id="remote-audio"
        data-remote-audio
        autoplay
        controls
        hidden
        playsinline
        class="sr-only"
      >
      </audio>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :language, :string, required: true

  defp waveform(assigns) do
    ~H"""
    <div id={@id} class="rounded-md border border-stone-200 bg-stone-50 p-3 sm:p-4">
      <div class="mb-4">
        <p class="text-sm font-semibold text-stone-800">{@label}</p>
        <p class="mt-1 text-sm text-stone-500">{@language}</p>
      </div>
      <canvas
        id={"#{@id}-canvas"}
        data-audio-visualizer={if(@id == "local-waveform", do: "local", else: "remote")}
        class="h-20 w-full rounded-md border border-stone-100 bg-white shadow-inner shadow-stone-100 sm:h-28"
      >
      </canvas>
    </div>
    """
  end

  defp extension_panel(assigns) do
    ~H"""
    <div id="extension-panel" class="col-span-full space-y-6 p-4 sm:p-7">
      <h2 class="text-3xl font-semibold tracking-normal text-stone-950">
        {gettext("Time is up. Continue for another 5 minutes?")}
      </h2>

      <div class="grid gap-2 sm:grid-cols-2 sm:gap-3">
        <button
          id="continue-call-button"
          phx-click="extension_vote"
          phx-value-vote="continue"
          class="rounded-md bg-stone-950 px-4 py-3 font-semibold text-white transition hover:-translate-y-0.5 hover:bg-teal-800 focus:outline-none focus:ring-4 focus:ring-teal-100"
        >
          {gettext("Continue")}
        </button>
        <button
          id="end-call-button"
          phx-click="extension_vote"
          phx-value-vote="end"
          class="rounded-md border border-red-200 px-4 py-3 font-semibold text-red-700 transition hover:border-red-700 hover:bg-red-50"
        >
          {gettext("End")}
        </button>
      </div>
    </div>
    """
  end

  defp transition(socket, to) do
    case ConversationFlow.transition(socket.assigns.ui_state, to) do
      {:ok, state} -> assign(socket, :ui_state, state)
      {:error, :invalid_transition} -> socket
    end
  end

  defp join_matchmaking(socket) do
    preferences = socket.assigns.preferences

    attrs = %{
      id: socket.assigns.participant_id,
      pid: self(),
      topic: socket.assigns.match_topic,
      speaks_language: preferences["speaking_language"],
      listens_language: preferences["listening_language"],
      accepted_adult_terms: acknowledged?(preferences)
    }

    case Matchmaker.join(attrs) do
      :queued ->
        transition(socket, :looking)

      {:matched, match} ->
        assign_match(socket, match)

      {:error, :already_queued} ->
        transition(socket, :looking)

      {:error, :adult_terms_required} ->
        assign(
          socket,
          :matchmaking_error,
          gettext("Accept the 18+ acknowledgment before looking for a rando.")
        )

      {:error, :unsupported_language} ->
        assign(socket, :matchmaking_error, gettext("Choose supported conversation languages."))
    end
  end

  defp maybe_leave_matchmaking(%{assigns: %{ui_state: :looking}} = socket, to)
       when to in [:idle, :connecting] do
    Matchmaker.leave(self())
    socket
  end

  defp maybe_leave_matchmaking(socket, _to), do: socket

  defp assign_match(socket, match) do
    {match_role, webrtc_role} = roles_for(match, socket.assigns.participant_id)

    socket
    |> assign(:match, match)
    |> assign(:match_role, match_role)
    |> assign(:webrtc_role, webrtc_role)
    |> assign(:call_pid, match.call_pid)
    |> assign(:call_status, :connecting)
    |> assign(:call_ended_reason, nil)
    |> assign(:extension_count, 0)
    |> assign(:stop_after_call?, true)
    |> assign(:matchmaking_error, nil)
    |> assign(:ui_state, :connecting)
  end

  defp assign_call_state(socket, call, ui_state) do
    socket
    |> assign(:call_pid, call.call_pid)
    |> assign(:call_status, call.status)
    |> assign(:call_deadline_unix_ms, call.call_deadline_unix_ms)
    |> assign(:extension_deadline_unix_ms, call.extension_deadline_unix_ms)
    |> assign(:extension_count, call.extension_count)
    |> assign(:call_ended_reason, call.ended_reason)
    |> assign(:ui_state, ui_state)
  end

  defp finish_call(socket, call) do
    socket =
      socket
      |> assign_call_state(call, :idle)
      |> assign(:call_pid, nil)
      |> assign(:match, nil)

    if socket.assigns.stop_after_call? do
      assign(socket, :ui_state, :idle)
    else
      join_matchmaking(socket)
    end
  end

  defp hang_up_current_call(socket) do
    if socket.assigns.call_pid do
      CallCoordinator.hang_up(socket.assigns.call_pid, socket.assigns.participant_id)
    end
  end

  defp relay_client_signal(socket, "extension_accepted", _payload) do
    if socket.assigns.call_pid do
      CallCoordinator.vote_extension(
        socket.assigns.call_pid,
        socket.assigns.participant_id,
        :continue
      )
    end

    socket
  end

  defp relay_client_signal(socket, "extension_declined", _payload) do
    socket = assign(socket, :stop_after_call?, true)

    if socket.assigns.call_pid do
      CallCoordinator.vote_extension(socket.assigns.call_pid, socket.assigns.participant_id, :end)
    end

    socket
  end

  defp relay_client_signal(socket, type, payload) do
    with call_pid when not is_nil(call_pid) <- socket.assigns.call_pid,
         {:ok, _type} <- Signaling.cast_type(type) do
      CallCoordinator.relay_signal(call_pid, socket.assigns.participant_id, type, payload)
    end

    socket
  end

  defp encode_signal(message) do
    %{
      call_id: message.call_id,
      type: Atom.to_string(message.type),
      from_participant_id: message.from_participant_id,
      to_participant_id: message.to_participant_id,
      payload: message.payload,
      sent_at_unix_ms: message.sent_at_unix_ms
    }
  end

  defp roles_for(%{participant_a: %{id: participant_id}}, participant_id),
    do: {:participant_a, :offerer}

  defp roles_for(%{participant_b: %{id: participant_id}}, participant_id),
    do: {:participant_b, :answerer}

  defp role_label(:participant_a), do: gettext("participant A")
  defp role_label(:participant_b), do: gettext("participant B")
  defp role_label(nil), do: gettext("unassigned")

  defp webrtc_role_label(:offerer), do: gettext("offerer")
  defp webrtc_role_label(:answerer), do: gettext("answerer")
  defp webrtc_role_label(nil), do: gettext("no WebRTC role")

  defp parse_state("idle"), do: :idle
  defp parse_state("looking"), do: :looking
  defp parse_state("connecting"), do: :connecting
  defp parse_state("in_call"), do: :in_call
  defp parse_state("extension_pending"), do: :extension_pending

  defp default_preferences do
    %{
      "speaking_language" => "en",
      "listening_language" => "es",
      "adult_acknowledgment" => "false"
    }
  end

  defp anonymous_participant_id do
    "anon-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
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

  defp acknowledged?(%{"adult_acknowledgment" => "true"}), do: true
  defp acknowledged?(_preferences), do: false

  defp assign_form(socket, preferences) do
    assign(socket, :form, to_form(preferences, as: :conversation))
  end

  defp language_options do
    [
      {gettext("English"), "en"},
      {gettext("Spanish"), "es"},
      {gettext("French"), "fr"},
      {gettext("German"), "de"},
      {gettext("Italian"), "it"},
      {gettext("Portuguese"), "pt"}
    ]
  end

  defp language_name("en"), do: gettext("English")
  defp language_name("es"), do: gettext("Spanish")
  defp language_name("fr"), do: gettext("French")
  defp language_name("de"), do: gettext("German")
  defp language_name("it"), do: gettext("Italian")
  defp language_name("pt"), do: gettext("Portuguese")
  defp language_name(code), do: ConversationLanguages.name(code)

  defp state_label(:idle), do: gettext("Ready")
  defp state_label(:looking), do: gettext("Looking")
  defp state_label(:connecting), do: gettext("Connecting")
  defp state_label(:in_call), do: gettext("In call")
  defp state_label(:extension_pending), do: gettext("Time is up")

  defp state_description(:idle), do: gettext("Choose your languages when you are ready.")
  defp state_description(:looking), do: gettext("Finding a compatible anonymous partner.")
  defp state_description(:connecting), do: gettext("A compatible rando is available.")
  defp state_description(:in_call), do: gettext("Conversation is active.")

  defp state_description(:extension_pending),
    do: gettext("Both people choose whether to continue.")

  defp progress_step_class(assigns, state) do
    if assigns.ui_state == state do
      "border-stone-950 bg-stone-950 text-white"
    else
      "border-stone-200 bg-white text-stone-500"
    end
  end
end
