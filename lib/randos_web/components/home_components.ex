defmodule RandosWeb.HomeComponents do
  @moduledoc """
  Function components for the home page (`RandosWeb.HomeLive`): the hero, the
  state progress list, and one panel per participant status.

  `hero_panel/1` and `conversation_card/1` are the entry points; the rest are
  private building blocks.
  """
  use RandosWeb, :html

  alias Randos.Calls.Lifecycle
  alias Randos.ConversationLanguages

  @doc "Whether the form's 18+ acknowledgment is checked."
  def acknowledged?(%{"adult_acknowledgment" => "true"}), do: true
  def acknowledged?(_preferences), do: false

  attr :ui_state, :atom, required: true
  attr :flow, :atom, default: :random

  def hero_panel(assigns) do
    ~H"""
    <%!-- Header and progress are separate items in the centered page grid. --%>
    <div id="hero-panel" class="contents">
      <div class="order-1 mx-auto w-full max-w-2xl text-center">
        <div class="flex items-center justify-center gap-3">
          <img src={~p"/images/logo.svg"} alt="" class="size-10 sm:size-12" />
          <h1 class="text-4xl font-semibold leading-none tracking-normal text-stone-950 sm:text-5xl">
            randos
          </h1>
        </div>
        <p class="mt-3 text-base leading-7 text-stone-700 sm:text-lg">
          {gettext("Short anonymous conversations for language practice.")}
        </p>
      </div>

      <.state_progress ui_state={@ui_state} flow={@flow} />
    </div>
    """
  end

  attr :ui_state, :atom, required: true
  attr :flow, :atom, default: :random

  # One list per way into a call: random matching, or an invitation (the
  # creator's steps, or the joiner's), so every step shown is true.
  defp state_progress(assigns) do
    assigns = assign(assigns, :steps, progress_steps(assigns.flow))

    ~H"""
    <ol
      id="state-progress"
      data-flow={@flow}
      aria-label={gettext("Call progress")}
      class="order-2 flex flex-wrap items-center justify-center gap-2"
    >
      <li
        :for={state <- @steps}
        id={"state-progress-#{state}"}
        aria-current={if state in lit_steps(@ui_state), do: "step"}
        class={[
          "rounded-full border px-3 py-1 text-xs font-medium transition-colors duration-200",
          progress_step_class(@ui_state, state)
        ]}
      >
        <span>{state_label(state)}</span>
        <span class="sr-only"> — {state_description(state)}</span>
      </li>
    </ol>
    """
  end

  attr :ui_state, :atom, required: true
  attr :call_id, :string, default: nil
  attr :call_status, :atom, default: nil
  attr :call_deadline_unix_ms, :integer, default: nil
  attr :webrtc_role, :atom, default: nil
  attr :preferences, :map, required: true
  attr :peer_languages, :list, default: []
  attr :peer_reconnecting, :boolean, default: false
  attr :recovering, :boolean, default: false
  attr :agreed_to_continue, :boolean, default: false
  attr :form, :any, required: true
  attr :matchmaking_error, :string, default: nil
  attr :notice, :string, default: nil
  attr :live_action, :atom, default: :home
  attr :join_link, :atom, default: :unknown
  attr :link_failed, :boolean, default: false
  attr :invitation, :map, default: nil
  attr :call_kind, :atom, default: nil

  attr :ice_servers, :string, default: nil
  attr :ice_transport_policy, :string, default: nil
  attr :ice_generation, :integer, default: 0
  attr :ice_restart, :boolean, default: false
  attr :voice_processor, :string, default: nil

  def conversation_card(assigns) do
    ~H"""
    <div
      id="conversation-card"
      class="order-3 grid w-full max-w-2xl min-w-0 grid-cols-1 justify-self-center overflow-hidden rounded-xl border border-stone-200 bg-white shadow-sm shadow-stone-200/70 sm:grid-cols-3"
    >
      <%!-- Keyed by call: a new call (even an instant rematch, in the same
           render) gets a new element and a fresh WebRTC hook, never the
           previous call's (#webrtc-audio itself is phx-update="ignore"). --%>
      <div
        :if={@call_status in [:connecting, :active, :extension_pending] && @webrtc_role}
        id={"call-media-#{@call_id}"}
        class="contents"
      >
        <.call_media_panel
          call_id={@call_id}
          webrtc_role={@webrtc_role}
          ice_servers={@ice_servers}
          ice_transport_policy={@ice_transport_policy}
          ice_generation={@ice_generation}
          ice_restart={@ice_restart}
          voice_processor={@voice_processor}
        />
      </div>

      <%= case @ui_state do %>
        <% :idle when @live_action == :join -> %>
          <.join_panel
            form={@form}
            preferences={@preferences}
            join_link={@join_link}
            link_failed={@link_failed}
            matchmaking_error={@matchmaking_error}
          />
        <% :idle -> %>
          <.idle_panel
            form={@form}
            preferences={@preferences}
            matchmaking_error={@matchmaking_error}
            notice={@notice}
          />
        <% :inviting -> %>
          <.inviting_panel invitation={@invitation} />
        <% :looking -> %>
          <.searching_panel preferences={@preferences} language_name={&language_name/1} />
        <% :connecting -> %>
          <.connecting_panel webrtc_role={@webrtc_role} />
        <% :in_call -> %>
          <.call_panel
            preferences={@preferences}
            peer_languages={@peer_languages}
            peer_reconnecting={@peer_reconnecting}
            recovering={@recovering}
            webrtc_role={@webrtc_role}
            language_name={&language_name/1}
          />
        <% :extension_pending -> %>
          <.extension_panel agreed_to_continue={@agreed_to_continue} />
      <% end %>

      <.voice_settings :if={@ui_state == :idle} />

      <.call_timer_panel
        :if={@ui_state == :in_call}
        call_status={@call_status}
        call_deadline_unix_ms={@call_deadline_unix_ms}
      />
      <.call_actions_panel :if={@ui_state == :in_call} call_kind={@call_kind} />
    </div>
    """
  end

  attr :form, :any, required: true
  attr :preferences, :map, required: true
  attr :matchmaking_error, :string, default: nil
  attr :notice, :string, default: nil

  defp idle_panel(assigns) do
    ~H"""
    <div id="idle-panel" class="col-span-full p-5 sm:p-7">
      <%!-- News, not an error: why the form came back (an invitation call ended). --%>
      <p
        :if={@notice}
        id="call-notice"
        role="status"
        class="mb-5 flex items-center gap-2 rounded-md border border-teal-100 bg-teal-50 px-4 py-3 text-sm font-medium text-teal-900"
      >
        <.icon name="hero-phone-x-mark" class="size-5 shrink-0" />
        {@notice}
      </p>
      <.form
        for={@form}
        id="conversation-form"
        phx-hook="ConversationPreferences"
        phx-change="update_preferences"
        phx-submit="find"
        class="space-y-5"
      >
        <.language_fields form={@form} preferences={@preferences} />

        <div class="rounded-md border border-stone-200 bg-stone-50 px-4 py-4">
          <.input
            field={@form[:adult_acknowledgment]}
            type="checkbox"
            label={
              gettext(
                "I am 18 or older and understand that conversations are anonymous and unmoderated."
              )
            }
            class="size-4 rounded border-stone-300 accent-teal-700 focus:ring-teal-600"
          />
        </div>

        <div id="conversation-actions" class="grid grid-cols-1 gap-3 sm:grid-cols-2">
          <button
            id="find-rando-button"
            type="submit"
            disabled={!acknowledged?(@preferences)}
            class={[
              "inline-flex w-full items-center justify-center gap-2 rounded-md border border-transparent px-5 py-3 text-base font-semibold transition duration-200",
              acknowledged?(@preferences) &&
                "bg-stone-950 text-white shadow-sm hover:-translate-y-0.5 hover:bg-teal-800 focus:outline-none focus:ring-4 focus:ring-teal-100 dark:bg-stone-100 dark:text-stone-950 dark:hover:bg-teal-300",
              !acknowledged?(@preferences) && "cursor-not-allowed bg-stone-200 text-stone-500"
            ]}
          >
            <.icon name="hero-magnifying-glass" class="size-5 shrink-0" />
            {pgettext("button", "Find a rando")}
          </button>

          <%!-- Quieter: bring someone you know instead (an invitation link). --%>
          <button
            id="invite-button"
            type="button"
            phx-click="invite"
            disabled={!acknowledged?(@preferences)}
            class={[
              "inline-flex w-full items-center justify-center gap-2 rounded-md border px-5 py-3 text-base font-semibold transition duration-200",
              acknowledged?(@preferences) &&
                "border-teal-600 bg-teal-50 text-teal-900 shadow-sm hover:-translate-y-0.5 hover:bg-teal-100 focus:outline-none focus:ring-4 focus:ring-teal-100 dark:hover:bg-teal-950",
              !acknowledged?(@preferences) &&
                "cursor-not-allowed border-stone-200 bg-stone-200 text-stone-500"
            ]}
          >
            <.icon name="hero-link" class="size-5 shrink-0" />
            <% gettext_comment(
              "Button: make a private link to share with someone you already know, instead of meeting a stranger."
            ) %>
            {pgettext("button", "Invite someone")}
          </button>
        </div>

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

  attr :invitation, :map, required: true

  # Waiting for the person invited: the link to share, and how to stop.
  defp inviting_panel(assigns) do
    ~H"""
    <div id="inviting-panel" class="col-span-full space-y-6 p-5 sm:p-7">
      <div>
        <p class="text-sm font-medium uppercase tracking-[0.16em] text-teal-700">
          <% gettext_comment(
            "Your status: you made an invitation link and wait for someone to open it."
          ) %>
          {gettext("Inviting")}
        </p>
        <h2 class="mt-3 text-3xl font-semibold tracking-normal text-stone-950">
          {gettext("Waiting for your rando to open the link…")}
        </h2>
        <p class="mt-3 leading-7 text-stone-600">
          {gettext("Send them this link however you like. It works once.")}
          <%!-- How long it keeps working, counting down (the call timer's hook). --%>
          <span
            id="invitation-countdown"
            phx-hook="CallCountdown"
            phx-update="ignore"
            data-deadline-unix-ms={@invitation.expires_at_unix_ms}
            data-labels={JSON.encode!(%{remaining: link_time_left_label()})}
            class="ms-1 font-medium tabular-nums text-teal-700"
          >
            <span data-countdown-value>
              {gettext("%{time} left",
                time: "#{div(Lifecycle.invitation_seconds(), 60)}:00"
              )}
            </span>
          </span>
        </p>
      </div>
      <div class="flex flex-col gap-2 sm:flex-row">
        <input
          id="invitation-url"
          type="text"
          readonly
          value={@invitation.url}
          aria-label={gettext("Invitation link")}
          class="min-w-0 flex-1 rounded-md border border-stone-300 bg-stone-50 px-3 py-3 font-mono text-sm text-stone-800"
        />
        <button
          id="copy-invitation-button"
          type="button"
          phx-hook="CopyLink"
          phx-update="ignore"
          data-url={@invitation.url}
          data-labels={JSON.encode!(%{copy: pgettext("button", "Copy"), copied: gettext("Copied")})}
          class="inline-flex items-center justify-center gap-2 rounded-md bg-stone-950 px-5 py-3 font-semibold text-white transition hover:bg-teal-800 dark:bg-stone-100 dark:text-stone-950 dark:hover:bg-teal-300"
        >
          <.icon name="hero-clipboard-document" class="size-5" />
          <span data-copy-label>{pgettext("button", "Copy")}</span>
        </button>
      </div>
      <div class="grid gap-3">
        <button
          id="cancel-invitation-button"
          phx-click="cancel_invitation"
          class="rounded-md border border-stone-300 px-5 py-3 font-semibold text-stone-700 transition hover:border-stone-950 hover:text-stone-950"
        >
          <% gettext_comment("Button: withdraw the invitation link, so it stops working.") %>
          {pgettext("button", "Cancel the link")}
        </button>
      </div>
    </div>
    """
  end

  attr :form, :any, required: true
  attr :preferences, :map, required: true
  attr :join_link, :atom, required: true
  attr :link_failed, :boolean, default: false
  attr :matchmaking_error, :string, default: nil

  # Where an invitation link lands. Once the link has failed (used,
  # expired, withdrawn, or not for this kind of client), only the message
  # stays: there's nothing to join. The JoinLink hook reads the token from
  # the URL fragment and puts it in the form only as it's submitted.
  defp join_panel(assigns) do
    ~H"""
    <div id="join-panel" class="col-span-full p-5 sm:p-7">
      <h2 class="text-3xl font-semibold tracking-normal text-stone-950">
        <% gettext_comment("Heading of the page an invitation link opens.") %>
        {gettext("Someone invited you to a call")}
      </h2>
      <p
        :if={@join_link == :missing}
        id="join-link-missing"
        class="mt-4 rounded-md border border-red-200 bg-red-50 px-4 py-3 text-sm font-medium text-red-700"
      >
        {gettext("This link is incomplete.")}
      </p>
      <.form
        :if={@join_link != :missing and not @link_failed}
        for={@form}
        id="join-form"
        phx-hook="JoinLink"
        phx-change="update_preferences"
        phx-submit="accept_invitation"
        class="mt-5 space-y-5"
      >
        <p class="leading-7 text-stone-600">
          {gettext(
            "A one-to-one audio call, like any other on randos, with the person who sent you the link."
          )}
        </p>
        <input type="hidden" name="token" value="" />
        <div class="rounded-md border border-stone-200 bg-stone-50 px-4 py-4">
          <.input
            field={@form[:adult_acknowledgment]}
            type="checkbox"
            label={
              gettext(
                "I am 18 or older and understand that conversations are anonymous and unmoderated."
              )
            }
            class="size-4 rounded border-stone-300 accent-teal-700 focus:ring-teal-600"
          />
        </div>
        <button
          id="join-call-button"
          type="submit"
          disabled={!acknowledged?(@preferences)}
          class={[
            "inline-flex w-full items-center justify-center gap-2 rounded-md px-5 py-3 text-base font-semibold transition duration-200",
            acknowledged?(@preferences) &&
              "bg-stone-950 text-white shadow-sm hover:-translate-y-0.5 hover:bg-teal-800 focus:outline-none focus:ring-4 focus:ring-teal-100 dark:bg-stone-100 dark:text-stone-950 dark:hover:bg-teal-300",
            !acknowledged?(@preferences) && "cursor-not-allowed bg-stone-200 text-stone-500"
          ]}
        >
          <.icon name="hero-phone" class="size-5" />
          {pgettext("button", "Join the call")}
        </button>
      </.form>
      <p
        :if={@matchmaking_error}
        id="matchmaking-error"
        class="mt-5 rounded-md border border-red-200 bg-red-50 px-4 py-3 text-sm font-medium text-red-700"
      >
        {@matchmaking_error}
      </p>
    </div>
    """
  end

  attr :form, :any, required: true
  attr :preferences, :map, required: true

  defp language_fields(assigns) do
    ~H"""
    <div class="space-y-4">
      <.input
        field={@form[:speaking_language]}
        type="select"
        label={gettext("I will speak in")}
        options={language_options()}
        class="w-full rounded-md border border-stone-300 bg-white px-3 py-3 text-base text-stone-950 shadow-sm outline-none transition focus:border-teal-600 focus:ring-4 focus:ring-teal-100"
      />
      <fieldset id="hearing-languages">
        <legend class="mb-1.5 text-sm font-semibold text-stone-800">
          {gettext("I want to hear")}
        </legend>
        <%!-- The choice in one line; "Change" opens the chips. Native
             <details>, no script. Start collapsed with the current choice
             visible; ignore_attributes preserves how the person leaves it. --%>
        <details
          id="hearing-details"
          class="group"
          phx-mounted={JS.ignore_attributes(["open"])}
        >
          <summary
            id="hearing-summary"
            class="flex cursor-pointer list-none items-center justify-between gap-3 rounded-md border border-stone-200 bg-white px-3 py-2.5 text-sm transition hover:border-stone-400 dark:hover:border-stone-500 [&::-webkit-details-marker]:hidden"
          >
            <span
              id="hearing-summary-text"
              data-hearing={Enum.join(@preferences["hearing_languages"], " ")}
              class="min-w-0 text-stone-800"
            >
              {hearing_line(@preferences["hearing_languages"])}
            </span>
            <span class="shrink-0 font-medium text-teal-700">
              <% gettext_comment("Opens the list of languages you can hear, to change it.") %>
              <span class="group-open:hidden">{gettext("Change")}</span>
              <% gettext_comment("Closes the list of languages you can hear, once you've changed it.") %>
              <span class="hidden group-open:inline">{gettext("Done")}</span>
            </span>
          </summary>
          <p class="mb-3 mt-3 text-sm text-stone-500">
            {gettext("Pick every language you're comfortable listening to.")}
          </p>
          <%!-- Submitted even with nothing checked, so unchecking all clears it. --%>
          <input type="hidden" name="conversation[hearing_languages][]" value="" />
          <div id="hearing-chips" class="flex flex-wrap gap-2">
            <label
              :for={{name, code} <- language_options()}
              id={"hearing-chip-#{code}"}
              for={"hearing-language-#{code}"}
              class="cursor-pointer"
            >
              <input
                type="checkbox"
                id={"hearing-language-#{code}"}
                name="conversation[hearing_languages][]"
                value={code}
                checked={code in @preferences["hearing_languages"]}
                class="peer sr-only"
              />
              <span class={[
                "inline-flex select-none items-center rounded-full border px-3 py-1.5 text-sm transition peer-focus-visible:outline-2 peer-focus-visible:outline-offset-2 peer-focus-visible:outline-teal-600",
                if(code in @preferences["hearing_languages"],
                  do:
                    "border-teal-600 bg-teal-600 text-white dark:border-teal-400 dark:bg-teal-400 dark:text-stone-950",
                  else:
                    "border-stone-300 bg-white text-stone-700 hover:border-stone-400 dark:hover:border-stone-500"
                )
              ]}>
                {name}
              </span>
            </label>
          </div>
        </details>
      </fieldset>
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
            "Looking for a rando who speaks %{hearing_languages} and wants to hear %{speaking_language}.",
            hearing_languages: hearing_summary(@preferences["hearing_languages"], @language_name),
            speaking_language: @language_name.(@preferences["speaking_language"])
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
          <% gettext_comment(
            "A button: stop searching for someone to talk to (not \"stop watching\")."
          ) %>
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
          <% gettext_comment(
            "The call's status: its audio is connecting right now (a state, not the action \"log in\")."
          ) %>
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
  attr :peer_languages, :list, default: []
  attr :peer_reconnecting, :boolean, default: false
  attr :recovering, :boolean, default: false
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
          <% gettext_comment(
            "Heading over the voice call in progress, with your conversation partner."
          ) %>
          {gettext("Current call")}
        </h2>
        <p
          :if={@peer_reconnecting}
          id="peer-reconnecting"
          role="status"
          class="mt-3 inline-flex items-center gap-2 rounded-md bg-stone-100 px-3 py-2 text-sm text-stone-700"
        >
          <.icon name="hero-arrow-path" class="size-4 text-teal-700 motion-safe:animate-spin" />
          {gettext("Your rando's connection dropped; waiting a few seconds for them to come back.")}
        </p>
        <%!-- The call is recovering (the server's budget, obligation 10): the
             audio may be cut for a few seconds. The rando's own drop says
             more, so it wins. --%>
        <p
          :if={@recovering and not @peer_reconnecting}
          id="call-recovering"
          role="status"
          class="mt-3 inline-flex items-center gap-2 rounded-md bg-stone-100 px-3 py-2 text-sm text-stone-700"
        >
          <.icon name="hero-arrow-path" class="size-4 text-teal-700 motion-safe:animate-spin" />
          {gettext("Reconnecting audio…")}
        </p>
      </div>

      <div class="grid gap-3 sm:grid-cols-2 sm:gap-4">
        <% gettext_comment(
          "Label of your own voice's waveform during a call (you, not the other person)."
        ) %>
        <.waveform
          id="local-waveform"
          label={gettext("You")}
          language={@language_name.(@preferences["speaking_language"])}
        />
        <.waveform
          id="remote-waveform"
          label={gettext("Your rando")}
          language={@peer_languages != [] && hearing_summary(@peer_languages, @language_name)}
        />
      </div>
    </div>
    """
  end

  attr :call_kind, :atom, default: nil

  # No "Next" in an invitation call: there's no next.
  defp call_actions_panel(assigns) do
    ~H"""
    <div class={[
      "order-3 col-span-full grid gap-2 border-t border-stone-200 px-4 py-3 sm:col-span-2 sm:gap-3 sm:border-s sm:px-7",
      @call_kind != :invitation && "sm:grid-cols-2"
    ]}>
      <button
        :if={@call_kind != :invitation}
        id="next-rando-button"
        phx-click="next_rando"
        class="inline-flex h-12 items-center justify-center rounded-md border border-stone-300 px-4 py-0 font-semibold leading-none text-stone-700 transition hover:border-stone-950 hover:text-stone-950"
      >
        <% gettext_comment("Button: end this call and find another person to talk to.") %>
        {pgettext("button", "Next rando")}
      </button>
      <button
        id="end-call-button"
        phx-click="end_call"
        class="inline-flex h-12 items-center justify-center rounded-md border border-red-200 px-4 py-0 font-semibold leading-none text-red-700 transition hover:border-red-700 hover:bg-red-50"
      >
        <% gettext_comment("Button: hang up, ending the call now.") %>
        {pgettext("button", "End")}
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
        data-labels={countdown_labels()}
        class="inline-flex items-center gap-2 font-medium text-stone-600"
      >
        <.icon name="hero-clock" class="size-4 text-teal-700" />
        <span id="call-countdown-value" data-countdown-value>
          {gettext("%{time} remaining", time: "--:--")}
        </span>
      </div>
    </div>
    """
  end

  attr :call_id, :string, default: nil
  attr :webrtc_role, :atom, required: true

  attr :ice_servers, :string, default: nil
  attr :ice_transport_policy, :string, default: nil
  attr :ice_generation, :integer, default: 0
  attr :ice_restart, :boolean, default: false
  attr :voice_processor, :string, default: nil

  defp call_media_panel(assigns) do
    ~H"""
    <div
      id="webrtc-audio"
      phx-hook="WebRTCAudio"
      phx-update="ignore"
      data-webrtc-role={@webrtc_role}
      data-call-id={@call_id}
      data-ice-servers={@ice_servers}
      data-ice-transport-policy={@ice_transport_policy}
      data-ice-generation={@ice_generation}
      data-ice-restart={to_string(@ice_restart)}
      data-offline-limit-ms={Randos.Calls.Lifecycle.offline_limit_seconds() * 1000}
      data-voice-processor={@voice_processor}
      data-webrtc-state="not_started"
      data-microphone-muted="false"
      data-labels={call_labels()}
      class="contents"
    >
      <div class="order-2 col-span-full flex flex-col gap-2 border-t border-stone-200 px-4 py-3 text-sm text-stone-500 sm:col-span-2 sm:h-full sm:flex-row sm:items-center sm:justify-between sm:px-7">
        <div class="min-w-0">
          <p class="flex flex-wrap items-center gap-x-1 gap-y-0.5">
            <% gettext_comment(
              "Label before the call's connection state (for example \"connecting\")."
            ) %>
            <span>{gettext("Connection:")}</span>
            <span id="webrtc-state-label" data-webrtc-status>
              {pgettext("connection state", "not started")}
            </span>
            <span id="microphone-status-label" data-microphone-status class="sr-only">
              {gettext("waiting for microphone")}
            </span>
            <span id="remote-audio-status-label" data-remote-audio-status class="sr-only">
              {gettext("waiting for remote audio")}
            </span>
          </p>
          <p data-voice-masking hidden class="text-teal-700">{gettext("Voice masking on")}</p>
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
          <% gettext_comment("Button: turn your own microphone off.") %>
          <span data-mute-label class="leading-none">{pgettext("button", "Mute")}</span>
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
  attr :language, :string, default: nil

  defp waveform(assigns) do
    ~H"""
    <div id={@id} class="rounded-md border border-stone-200 bg-stone-50 p-3 sm:p-4">
      <div class="mb-4">
        <p class="text-sm font-semibold text-stone-800">{@label}</p>
        <p id={"#{@id}-language"} class="mt-1 text-sm text-stone-500">{@language}</p>
      </div>
      <canvas
        id={"#{@id}-canvas"}
        data-audio-visualizer={if(@id == "local-waveform", do: "local", else: "remote")}
        class="h-20 w-full rounded-md border border-stone-100 bg-white shadow-inner shadow-stone-100 sm:h-28"
      ></canvas>
    </div>
    """
  end

  attr :agreed_to_continue, :boolean, default: false

  defp extension_panel(assigns) do
    ~H"""
    <div id="extension-panel" class="col-span-full space-y-6 p-4 sm:p-7">
      <h2 class="text-3xl font-semibold tracking-normal text-stone-950">
        {gettext("Time is up. Continue for another %{minutes} minutes?",
          minutes: div(Lifecycle.extension_duration_seconds(), 60)
        )}
      </h2>

      <div class="grid gap-2 sm:grid-cols-2 sm:gap-3">
        <p
          :if={@agreed_to_continue}
          id="extension-waiting"
          role="status"
          class="flex items-center gap-2 rounded-md border border-teal-100 bg-teal-50 px-4 py-3 text-sm font-medium text-teal-900"
        >
          <.icon name="hero-check-circle" class="size-5 shrink-0" />
          <% gettext_comment(
            "When the call's time is up, after you chose to keep talking: the other person hasn't chosen yet."
          ) %>
          {gettext("You agreed to continue, waiting on your rando…")}
        </p>
        <button
          :if={!@agreed_to_continue}
          id="continue-call-button"
          phx-click="extension_vote"
          phx-value-vote="continue"
          class="rounded-md bg-stone-950 px-4 py-3 font-semibold text-white transition hover:-translate-y-0.5 hover:bg-teal-800 dark:bg-stone-100 dark:text-stone-950 dark:hover:bg-teal-300 focus:outline-none focus:ring-4 focus:ring-teal-100"
        >
          <% gettext_comment(
            "Button: when the call's time is up, vote to keep talking a few more minutes."
          ) %>
          {pgettext("button", "Continue")}
        </button>
        <button
          id="end-call-button"
          phx-click="extension_vote"
          phx-value-vote="end"
          class="rounded-md border border-red-200 px-4 py-3 font-semibold text-red-700 transition hover:border-red-700 hover:bg-red-50"
        >
          {pgettext("button", "End")}
        </button>
      </div>
    </div>
    """
  end

  defp language_options do
    ConversationLanguages.all()
  end

  defp language_name(code), do: ConversationLanguages.name(code)

  defp progress_steps(:invite),
    do: [:inviting, :waiting, :connecting, :in_call, :extension_pending]

  defp progress_steps(:join), do: [:joining, :connecting, :in_call, :extension_pending]
  defp progress_steps(:random), do: [:idle, :looking, :connecting, :in_call, :extension_pending]

  defp state_label(:inviting) do
    gettext_comment("Your status: making a private link for someone you know.")
    gettext("Invite")
  end

  defp state_label(:waiting) do
    gettext_comment("Your status: your invitation link waits for the person you sent it to.")
    gettext("Waiting")
  end

  defp state_label(:joining) do
    gettext_comment("Your status: about to join the call an invitation link offers.")
    gettext("Join")
  end

  defp state_label(:idle) do
    gettext_comment("Your status before a call: ready to look for someone to talk to.")
    gettext("Ready")
  end

  defp state_label(:looking) do
    gettext_comment("Your status: searching for someone to talk to.")
    gettext("Looking")
  end

  defp state_label(:connecting), do: gettext("Connecting")
  defp state_label(:in_call), do: gettext("In call")

  defp state_label(:extension_pending) do
    gettext_comment(
      "Your status when the call's time has run out and both people choose whether to go on."
    )

    gettext("Time is up")
  end

  defp state_description(:inviting), do: gettext("Share a link.")
  defp state_description(:waiting), do: gettext("For your rando to open it.")
  defp state_description(:joining), do: gettext("Tick the 18+ box.")
  defp state_description(:idle), do: gettext("Choose your languages.")
  defp state_description(:looking), do: gettext("Finding a compatible rando.")
  defp state_description(:connecting), do: gettext("Starting call with rando.")
  defp state_description(:in_call), do: gettext("Conversation is active.")

  defp state_description(:extension_pending),
    do: gettext("Both people choose whether to continue.")

  defp progress_step_class(ui_state, state) do
    if state in lit_steps(ui_state) do
      "border-stone-950 bg-stone-950 text-white dark:border-stone-100 dark:bg-stone-100 dark:text-stone-950"
    else
      "border-stone-200 bg-white text-stone-500"
    end
  end

  # The steps a status lights up (only one is in any list): inviting is the
  # creator's "Waiting", and idle on /join the joiner's "Join".
  defp lit_steps(:inviting), do: [:waiting]
  defp lit_steps(:idle), do: [:idle, :joining]
  defp lit_steps(ui_state), do: [ui_state]

  # Text the call hook sets itself (assets/js/randos/labels.js), translated
  # here; the hook falls back to English for a missing key.
  defp call_labels do
    # A translator comment applies to the next string, so these are bound first.
    gettext_comment("Button: turn your own microphone back on.")
    unmute = pgettext("button", "Unmute")

    gettext_comment(
      "Status beside your microphone while the browser asks your permission to use it."
    )

    requesting_microphone = gettext("asking for microphone access")

    gettext_comment(
      "The call's state while the browser asks your permission to use the microphone."
    )

    requesting_state = pgettext("connection state", "asking for microphone access")

    JSON.encode!(%{
      mute: pgettext("button", "Mute"),
      unmute: unmute,
      microphone_ready: gettext("microphone ready"),
      requesting_microphone: requesting_microphone,
      microphone_unavailable: gettext("microphone unavailable"),
      waiting_for_remote_audio: gettext("waiting for remote audio"),
      remote_audio_received: gettext("remote audio received (%{summary})", summary: "%{summary}"),
      remote_audio_playing: gettext("remote audio playing (%{summary})", summary: "%{summary}"),
      remote_audio_needs_tap:
        gettext("remote audio needs a tap (%{summary})", summary: "%{summary}"),
      # One per WebRTCClientState (assets/js/randos/webrtc_client.js).
      state_not_started: pgettext("connection state", "not started"),
      state_requesting_microphone: requesting_state,
      state_microphone_denied: pgettext("connection state", "microphone denied"),
      state_creating_peer_connection: pgettext("connection state", "starting"),
      state_waiting_for_offer: pgettext("connection state", "waiting for your rando"),
      state_offer_sent: pgettext("connection state", "calling"),
      state_answer_sent: pgettext("connection state", "answering"),
      state_ice_checking: pgettext("connection state", "connecting"),
      state_connected: pgettext("connection state", "connected"),
      state_failed: pgettext("connection state", "failed"),
      state_closed: pgettext("connection state", "ended")
    })
  end

  defp link_time_left_label do
    gettext_comment("How long an invitation link keeps working, as m:ss (it counts down).")
    gettext("%{time} left", time: "%{time}")
  end

  defp countdown_labels,
    do: JSON.encode!(%{remaining: gettext("%{time} remaining", time: "%{time}")})

  # The hearing choice's one-line summary (the TUI's rule: up to three
  # names, then a count).
  defp hearing_line([]), do: gettext("Pick at least one language to hear")

  defp hearing_line(codes),
    do: gettext("You'll hear %{languages}", languages: hearing_summary(codes, &language_name/1))

  # "English, Español or Français"; past three, a count, so a long choice
  # doesn't make a long sentence.
  @listed_languages 3

  defp hearing_summary(codes, language_name) when length(codes) <= @listed_languages do
    case Enum.map(codes, language_name) do
      [only] ->
        only

      names ->
        gettext("%{first} or %{last}",
          first: names |> Enum.drop(-1) |> Enum.join(", "),
          last: List.last(names)
        )
    end
  end

  defp hearing_summary(codes, _language_name) do
    ngettext(
      "any of the %{count} language you picked",
      "any of the %{count} languages you picked",
      length(codes)
    )
  end

  def keyboard_shortcuts(assigns) do
    ~H"""
    <div
      id="homepage-shortcuts"
      phx-hook="HomeShortcuts"
      phx-update="ignore"
      class="order-4 w-full max-w-2xl justify-self-center text-center"
    >
      <div class="flex min-h-6 items-center justify-center gap-2">
        <button
          id="homepage-shortcuts-help"
          type="button"
          aria-controls="homepage-shortcuts-panel"
          aria-expanded="false"
          class="rounded-md px-3 py-1 text-xs text-stone-500 transition-colors hover:bg-stone-100 hover:text-teal-700"
        >
          <kbd class="me-1 font-mono">?</kbd> {pgettext("button", "Keyboard shortcuts")}
        </button>
        <button
          id="homepage-shortcuts-close"
          hidden
          type="button"
          aria-label={pgettext("button", "Hide shortcuts")}
          class="inline-flex items-center gap-1.5 rounded px-2 py-0.5 text-xs text-stone-600 hover:bg-stone-100 hover:text-teal-700"
        >
          <kbd class="rounded border border-stone-300 px-1 font-mono">Esc</kbd>
          <span>{pgettext("button", "Hide shortcuts")}</span>
        </button>
      </div>
      <section
        id="homepage-shortcuts-panel"
        hidden
        aria-label={gettext("Keyboard shortcuts")}
        class="rounded-xl border border-stone-200 bg-stone-100 p-3 text-start text-stone-950"
      >
        <div class="grid gap-3 sm:grid-cols-3">
          <.shortcut_group
            title={gettext("Conversation")}
            entries={[
              {"a", "A", gettext("Acknowledge")},
              {"c", "C", gettext("I will speak in")},
              {"f", "F", pgettext("button", "Find")},
              {"i", "I", pgettext("button", "Invite")},
              {"x", "X", pgettext("button", "Stop looking")},
              {"e", "E",
               (
                 gettext_comment("Short keyboard shortcut label: hang up the current voice call.")
                 gettext("End call")
               )},
              {"n", "N", pgettext("button", "Next rando")}
            ]}
          />
          <.shortcut_group
            title={gettext("Voice")}
            entries={[
              {"b", "B", gettext("Masking")},
              {"p", "P", gettext("Preview")},
              {"s", "S", gettext("Style")},
              {"t", "T", gettext("Tone")},
              {"m", "M",
               (
                 gettext_comment(
                   "Keyboard shortcut: turn your microphone off or on during a voice call."
                 )

                 gettext("Mute/unmute")
               )}
            ]}
          />
          <.shortcut_group
            title={gettext("Site")}
            entries={[
              {"o", "O", gettext("About")},
              {"r", "R", gettext("Server Status")},
              {"l", "L", gettext("Language menu")}
            ]}
          />
        </div>
      </section>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :entries, :list, required: true

  defp shortcut_group(assigns) do
    ~H"""
    <div data-shortcut-group class="min-w-0">
      <h3 class="mb-1 text-[0.65rem] font-semibold uppercase tracking-wider text-stone-500">
        {@title}
      </h3>
      <dl class="flex flex-wrap gap-x-3 gap-y-1">
        <div
          :for={{action, key, label} <- @entries}
          data-shortcut={action}
          class="inline-flex items-center gap-2 text-xs"
        >
          <dt class="order-2 text-stone-700">{label}</dt>
          <dd>
            <kbd class="inline-flex min-w-6 justify-center rounded border border-stone-300 bg-stone-50 px-1.5 py-0.5 font-mono font-semibold text-teal-700 shadow-sm">{key}</kbd>
          </dd>
        </div>
      </dl>
    </div>
    """
  end

  def voice_settings(assigns) do
    assigns =
      assign(assigns, :voice_form, to_form(%{"family" => "off", "tone" => "fuller"}, as: :voice))

    ~H"""
    <details
      id="voice-settings"
      phx-hook="VoiceSettings"
      phx-update="ignore"
      class="group col-span-full border-t border-stone-200"
      data-labels={
        Jason.encode!(%{
          opening: gettext("Opening microphone…"),
          active: gettext("Microphone on."),
          stopped: gettext("Microphone off."),
          failed: gettext("Preview failed. Microphone stopped; try again."),
          choice: gettext("%{style} + %{tone}", style: "%{style}", tone: "%{tone}"),
          hear:
            (
              gettext_comment(
                "Short button label: listen to your own microphone locally to try a changed voice."
              )

              pgettext("button", "Hear myself")
            ),
          stop:
            (
              gettext_comment(
                "Short button label: stop listening to the local microphone preview, not a call."
              )

              pgettext("button", "Stop preview")
            )
        })
      }
    >
      <summary
        id="voice-settings-toggle"
        class="flex cursor-pointer list-none items-center gap-2 px-5 py-4 text-sm font-medium text-stone-700 hover:text-teal-700 sm:px-7 [&::-webkit-details-marker]:hidden"
      >
        <.icon name="hero-voice-waveform" class="size-4 shrink-0" />
        <span class="shrink-0">{gettext("Voice masking")}</span>
        <span
          id="voice-choice-label"
          class="ms-auto min-w-0 max-w-[50%] text-end text-xs text-stone-500"
        >{gettext("Off")}</span>
        <.icon
          name="hero-chevron-down"
          class="size-4 transition-transform group-open:rotate-180"
        />
      </summary>
      <div class="px-5 pb-5 sm:px-7">
        <p id="voice-masking-warning" role="note" class="font-mono text-xs leading-5 text-stone-500">
          {gettext("These styles change your voice, but people may still recognize you.")}
        </p>
        <.form
          for={@voice_form}
          id="voice-settings-form"
          class="mt-4 grid gap-3 lg:grid-cols-1"
        >
          <.input
            field={@voice_form[:family]}
            id="voice-family"
            type="select"
            label={gettext("Style")}
            options={[
              {gettext("Off"), "off"},
              {(
                 gettext_comment(
                   "Voice masking style: change the voice's timbre or resonance, without changing its pitch. Not emotional tone."
                 )

                 gettext("Tone")
               ), "tone"},
              {(
                 gettext_comment(
                   "Voice masking style: change both vocal timbre and pitch (how high or low the voice sounds)."
                 )

                 gettext("Tone + Pitch")
               ), "tone_pitch"}
            ]}
          />
          <div id="voice-tone-choice" hidden>
            <.input
              field={@voice_form[:tone]}
              id="voice-tone"
              type="select"
              label={gettext("Tone")}
              options={[
                {(
                   gettext_comment(
                     "Voice timbre option: a fuller-sounding voice with lower resonances and more body. Not completeness or a person's name."
                   )

                   gettext("Fuller")
                 ), "fuller"},
                {(
                   gettext_comment(
                     "Voice timbre option: a brighter-sounding voice with higher resonances. Describes sound, not light or intelligence."
                   )

                   gettext("Brighter")
                 ), "brighter"}
              ]}
            />
          </div>
        </.form>
        <p id="voice-preview-info" role="note" class="mt-3 text-xs text-stone-500">
          {gettext("Headphones recommended")}
        </p>
        <button
          id="voice-preview"
          type="button"
          class="mt-3 inline-flex items-center gap-2 rounded-md border border-stone-300 px-3 py-2 text-sm font-semibold disabled:opacity-50"
        >
          <span data-voice-preview-play><.icon name="hero-play-solid" class="size-4" /></span>
          <span data-voice-preview-stop hidden><.icon name="hero-stop-solid" class="size-4" /></span>
          <span data-voice-preview-label>{pgettext(
            "button",
            "Hear myself"
          )}</span>
        </button>
        <p
          id="voice-preview-status"
          class="mt-2 font-mono text-xs leading-5 text-stone-600"
          role="status"
        >
          {gettext("Microphone off.")}
        </p>
        <p class="mt-2 text-xs text-stone-500">
          {gettext("Nothing is recorded or uploaded.")}
        </p>
      </div>
    </details>
    """
  end
end
