defmodule RandosWeb.HomeLive do
  @moduledoc """
  The web shell around `Randos.Participant`.

  Browser events and PubSub messages become participant events; the effects
  the participant returns are run here (matchmaker, call coordinator,
  `push_event`). This module owns only web concerns: the form, error copy,
  and rendering.
  """
  use RandosWeb, :live_view

  alias Randos.Calls.CallCoordinator
  alias Randos.ConversationLanguages
  alias Randos.Matchmaking.Matchmaker
  alias Randos.Participant
  alias RandosWeb.IceServers

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

  ## Running the participant core

  defp run(socket, event) do
    {participant, effects} = Participant.handle(socket.assigns.participant, event)
    Enum.reduce(effects, assign_participant(socket, participant), &run_effect/2)
  end

  defp run_effect({:join_queue, attrs}, socket) do
    run(socket, {:join_result, Matchmaker.join(Map.put(attrs, :pid, self()))})
  end

  defp run_effect(:leave_queue, socket) do
    Matchmaker.leave(self())
    socket
  end

  defp run_effect({:hang_up, call_pid}, socket) do
    CallCoordinator.hang_up(call_pid, socket.assigns.participant.id)
    socket
  end

  defp run_effect({:vote, call_pid, vote}, socket) do
    CallCoordinator.vote_extension(call_pid, socket.assigns.participant.id, vote)
    socket
  end

  defp run_effect({:relay_signal, call_pid, type, payload}, socket) do
    CallCoordinator.relay_signal(call_pid, socket.assigns.participant.id, type, payload)
    socket
  end

  defp run_effect({:push_signal, message}, socket) do
    push_event(socket, "randos:signal", message)
  end

  # Templates read these flat assigns, derived from the participant.
  defp assign_participant(socket, %Participant{} = participant) do
    socket
    |> assign_ice_servers(participant)
    |> assign(:participant, participant)
    |> assign(:ui_state, participant.status)
    |> assign(:webrtc_role, participant.webrtc_role)
    |> assign(:call_status, participant.call && participant.call.status)
    |> assign(:call_deadline_unix_ms, participant.call && participant.call.call_deadline_unix_ms)
    |> assign(:matchmaking_error, error_message(participant.error))
  end

  # Fresh STUN/TURN credentials for every new call, so they can never be older
  # than the call that uses them (they used to be minted once per page load).
  defp assign_ice_servers(socket, %Participant{call_pid: call_pid}) do
    previous = socket.assigns[:participant]

    cond do
      call_pid == nil -> assign(socket, :ice_servers, nil)
      previous && previous.call_pid == call_pid -> socket
      true -> assign(socket, :ice_servers, IceServers.json())
    end
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

  attr :ui_state, :atom, required: true

  defp hero_panel(assigns) do
    ~H"""
    <div id="hero-panel" class="flex flex-col justify-between gap-10">
      <div>
        <div class="flex items-center gap-3 sm:gap-4">
          <img src={~p"/images/logo.svg"} alt="" class="size-12 sm:size-16" />
          <h1 class="text-4xl font-semibold leading-none tracking-normal text-stone-950 sm:text-7xl">
            {gettext("Randos")}
          </h1>
        </div>
        <p class="mt-4 max-w-xl text-lg leading-7 text-stone-700 sm:mt-6 sm:text-xl sm:leading-8">
          {gettext("Short anonymous conversations for language practice.")}
        </p>
        <p class="mt-3 text-base text-stone-500">
          {gettext("No accounts. No profiles. No video. No pressure.")}
        </p>
      </div>

      <.state_progress ui_state={@ui_state} />
    </div>
    """
  end

  attr :ui_state, :atom, required: true

  defp state_progress(assigns) do
    ~H"""
    <div
      id="state-progress"
      class="grid grid-cols-1 gap-2 text-sm min-[420px]:grid-cols-2 sm:grid-cols-5 lg:grid-cols-1"
    >
      <div
        :for={state <- [:idle, :looking, :connecting, :in_call, :extension_pending]}
        id={"state-progress-#{state}"}
        class={[
          "rounded-md border px-3 py-2 transition-colors duration-200 sm:px-4 sm:py-3",
          progress_step_class(@ui_state, state)
        ]}
      >
        <p class="font-semibold">{state_label(state)}</p>
        <p class="mt-1 text-xs leading-5 opacity-75">{state_description(state)}</p>
      </div>
    </div>
    """
  end

  attr :ui_state, :atom, required: true
  attr :call_status, :atom, default: nil
  attr :call_deadline_unix_ms, :integer, default: nil
  attr :webrtc_role, :atom, default: nil
  attr :preferences, :map, required: true
  attr :form, :any, required: true
  attr :matchmaking_error, :string, default: nil

  attr :ice_servers, :string, default: nil

  defp conversation_card(assigns) do
    ~H"""
    <div class="grid min-w-0 grid-cols-1 overflow-hidden rounded-lg border border-stone-200 bg-white shadow-sm shadow-stone-200/70 sm:grid-cols-3">
      <.call_media_panel
        :if={@call_status in [:active, :extension_pending] && @webrtc_role}
        webrtc_role={@webrtc_role}
        ice_servers={@ice_servers}
      />

      <%= case @ui_state do %>
        <% :idle -> %>
          <.idle_panel
            form={@form}
            preferences={@preferences}
            matchmaking_error={@matchmaking_error}
          />
        <% :looking -> %>
          <.searching_panel preferences={@preferences} language_name={&language_name/1} />
        <% :connecting -> %>
          <.connecting_panel webrtc_role={@webrtc_role} />
        <% :in_call -> %>
          <.call_panel
            preferences={@preferences}
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
    """
  end

  attr :form, :any, required: true
  attr :preferences, :map, required: true
  attr :matchmaking_error, :string, default: nil

  defp idle_panel(assigns) do
    ~H"""
    <div id="idle-panel" class="col-span-full p-5 sm:p-7">
      <.form
        for={@form}
        id="conversation-form"
        phx-change="update_preferences"
        phx-submit="find"
        class="space-y-5"
      >
        <.language_fields form={@form} />

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
            !acknowledged?(@preferences) && "cursor-not-allowed bg-stone-200 text-stone-500"
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
    """
  end

  attr :form, :any, required: true

  defp language_fields(assigns) do
    ~H"""
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
    """
  end

  attr :preferences, :map, required: true
  attr :language_name, :any, required: true

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
          {gettext(
            "Looking for a rando speaking %{speaking_language} who wants to hear %{listening_language}.",
            speaking_language: @language_name.(@preferences["listening_language"]),
            listening_language: @language_name.(@preferences["speaking_language"])
          )}
        </p>
      </div>
      <div class="h-2 overflow-hidden rounded-full bg-stone-100">
        <div class="h-full w-1/2 rounded-full bg-teal-700 motion-safe:animate-pulse"></div>
      </div>
      <div class="grid gap-3">
        <button
          id="cancel-search-button"
          phx-click="cancel_search"
          class="rounded-md border border-stone-300 px-5 py-3 font-semibold text-stone-700 transition hover:border-stone-950 hover:text-stone-950"
        >
          {gettext("Stop looking")}
        </button>
      </div>
    </div>
    """
  end

  attr :webrtc_role, :atom, default: nil

  defp connecting_panel(assigns) do
    ~H"""
    <div
      id="connecting-panel"
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
      <p
        :if={@webrtc_role}
        id="match-connection-label"
        class="rounded-md border border-teal-100 bg-teal-50 px-4 py-3 text-sm font-medium text-teal-900"
      >
        {gettext("Secure audio connection is starting.")}
      </p>
      <div class="grid gap-3 sm:grid-cols-2">
        <button
          id="cancel-connection-button"
          phx-click="end_call"
          class="rounded-md border border-stone-300 px-5 py-3 font-semibold text-stone-700 transition hover:border-stone-950 hover:text-stone-950"
        >
          {gettext("Cancel")}
        </button>
      </div>
    </div>
    """
  end

  attr :preferences, :map, required: true
  attr :webrtc_role, :atom, default: nil
  attr :language_name, :any, required: true

  defp call_panel(assigns) do
    ~H"""
    <div
      id="call-panel"
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
    <div class="order-2 col-span-full flex border-t border-stone-200 px-4 py-3 text-sm text-stone-500 sm:col-span-1 sm:h-full sm:items-center sm:justify-end sm:px-7">
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

  attr :webrtc_role, :atom, required: true

  attr :ice_servers, :string, default: nil

  defp call_media_panel(assigns) do
    ~H"""
    <div
      id="webrtc-audio"
      phx-hook="WebRTCAudio"
      phx-update="ignore"
      data-webrtc-role={@webrtc_role}
      data-ice-servers={@ice_servers}
      data-webrtc-state="not_started"
      data-microphone-muted="false"
      class="contents"
    >
      <div class="order-2 col-span-full flex flex-col gap-2 border-t border-stone-200 px-4 py-3 text-sm text-stone-500 sm:col-span-2 sm:h-full sm:flex-row sm:items-center sm:justify-between sm:px-7">
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
          <span data-mute-icon class="inline-flex">
            <.icon name="hero-speaker-x-mark" class="size-5 shrink-0" />
          </span>
          <span data-unmute-icon hidden>
            <.icon name="hero-speaker-wave" class="size-5 shrink-0" />
          </span>
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
      ></audio>
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
      ></canvas>
    </div>
    """
  end

  defp extension_panel(assigns) do
    ~H"""
    <div id="extension-panel" class="col-span-full space-y-6 p-4 sm:p-7">
      <h2 class="text-3xl font-semibold tracking-normal text-stone-950">
        {gettext("Time is up. Continue for another 10 minutes?")}
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

  defp acknowledged?(%{"adult_acknowledgment" => "true"}), do: true
  defp acknowledged?(_preferences), do: false

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

  defp language_options do
    ConversationLanguages.all()
  end

  defp language_name(code), do: ConversationLanguages.name(code)

  defp state_label(:idle), do: gettext("Ready")
  defp state_label(:looking), do: gettext("Looking")
  defp state_label(:connecting), do: gettext("Connecting")
  defp state_label(:in_call), do: gettext("In call")
  defp state_label(:extension_pending), do: gettext("Time is up")

  defp state_description(:idle), do: gettext("Choose your languages.")
  defp state_description(:looking), do: gettext("Finding a compatible rando.")
  defp state_description(:connecting), do: gettext("Starting call with rando.")
  defp state_description(:in_call), do: gettext("Conversation is active.")

  defp state_description(:extension_pending),
    do: gettext("Both people choose whether to continue.")

  defp progress_step_class(ui_state, state) do
    if ui_state == state do
      "border-stone-950 bg-stone-950 text-white"
    else
      "border-stone-200 bg-white text-stone-500"
    end
  end
end
