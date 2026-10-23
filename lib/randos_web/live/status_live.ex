defmodule RandosWeb.StatusLive do
  @moduledoc """
  The public status page: whether the relay works and today's aggregate
  call counts. Renders only `RandosWeb.Status`'s snapshot, refreshed when
  the relay health or the counts announce a change.
  """
  use RandosWeb, :live_view

  alias Randos.ConversationLanguages
  alias Randos.Stats
  alias RandosWeb.RelayHealth
  alias RandosWeb.Status

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Randos.PubSub, RelayHealth.topic())
      Phoenix.PubSub.subscribe(Randos.PubSub, Stats.topic())
      # A machine that just woke has an old (or no) result: check now.
      RelayHealth.refresh_if_stale()
    end

    gettext_comment(
      "The service status page: whether calls can connect now, and today's call counts."
    )

    {:ok, assign(socket, page_title: gettext("Status"), status: Status.snapshot())}
  end

  @impl true
  def handle_info({:relay_health, _status}, socket),
    do: {:noreply, assign(socket, :status, Status.snapshot())}

  def handle_info({:stats_updated, _stats}, socket),
    do: {:noreply, assign(socket, :status, Status.snapshot())}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="min-h-[calc(100vh-5rem)] bg-stone-50 text-stone-950">
        <article class="mx-auto max-w-3xl px-4 py-10 sm:px-8 sm:py-16">
          <header class="space-y-3">
            <h1 class="text-4xl font-semibold tracking-normal text-stone-950">
              {gettext("Status")}
            </h1>
            <p class="text-lg leading-8 text-stone-700">
              {gettext("Whether calls can connect right now, and how today is going.")}
            </p>
          </header>

          <.relay relay={@status["relay"]} />
          <.usage usage={@status["usage"]} />
        </article>
      </div>
    </Layouts.app>
    """
  end

  attr :relay, :map, required: true

  defp relay(assigns) do
    ~H"""
    <section
      id="relay-status"
      data-state={@relay["state"]}
      class="mt-10 rounded-lg border border-stone-200 bg-white p-5 sm:p-6"
    >
      <div class="flex items-start gap-3">
        <span class={["mt-1.5 size-2.5 shrink-0 rounded-full", state_dot(@relay["state"])]}></span>
        <div class="space-y-1">
          <h2 class="text-xl font-semibold tracking-normal text-stone-950">
            {relay_headline(@relay["state"])}
          </h2>
          <p class="text-sm leading-6 text-stone-600">
            {gettext(
              "Every call goes through our relay, so neither person sees the other's address. We test it every few minutes by setting up a real relay connection."
            )}
          </p>
        </div>
      </div>

      <ul :if={@relay["transports"] != []} class="mt-5 divide-y divide-stone-100">
        <li
          :for={transport <- @relay["transports"]}
          id={"relay-#{transport["transport"]}"}
          data-ok={to_string(transport["ok"])}
          class="flex items-center justify-between gap-4 py-2.5 text-sm"
        >
          <span class="font-medium text-stone-800">{transport_name(transport["transport"])}</span>
          <span class={
            if transport["ok"], do: "text-teal-700", else: "text-red-700 dark:text-red-400"
          }>
            <% gettext_comment("A relay server's state on the status page: it is working (up).") %>
            {if transport["ok"],
              do: gettext("working"),
              else: RandosWeb.RelayReasons.message(transport["reason"])}
          </span>
        </li>
      </ul>

      <p :if={@relay["checked_at"]} id="relay-checked-at" class="mt-3 text-xs text-stone-500">
        {gettext("Last checked at %{time} UTC.", time: clock(@relay["checked_at"]))}
      </p>
    </section>
    """
  end

  attr :usage, :map, required: true

  defp usage(assigns) do
    ~H"""
    <section id="usage-counts" class="mt-8 space-y-6">
      <div class="space-y-1">
        <h2 class="text-xl font-semibold tracking-normal text-stone-950">{gettext("Today")}</h2>
        <p id="usage-since" class="text-sm leading-6 text-stone-600">
          {if @usage["kept_across_restarts"],
            do:
              gettext(
                "Counting since %{time} UTC on %{date}: today's calls so far.",
                time: clock(@usage["since"]),
                date: @usage["date"]
              ),
            else:
              gettext(
                "Counting since %{time} UTC on %{date}. This server starts fresh whenever it sleeps or is updated, so these are today's calls since then.",
                time: clock(@usage["since"]),
                date: @usage["date"]
              )}
        </p>
        <p
          :if={@usage["nodes"]["total"] > 1}
          id="usage-nodes"
          class="text-sm leading-6 text-stone-600"
        >
          {gettext("Counted across %{answered} of %{total} servers.",
            answered: @usage["nodes"]["answered"],
            total: @usage["nodes"]["total"]
          )}
        </p>
      </div>

      <dl class="grid grid-cols-2 gap-3 sm:grid-cols-4">
        <% gettext_comment("A count on the status page: how many calls started today.") %>
        <.count id="usage-started" label={gettext("Calls started")} value={@usage["calls_started"]} />
        <% gettext_comment("A count on the status page: how many calls connected today.") %>
        <.count
          id="usage-connected"
          label={gettext("Connected")}
          value={@usage["calls_connected"]}
        />
        <% gettext_comment(
          "A count on the status page: calls that were continued past their first minutes."
        ) %>
        <.count
          id="usage-continued"
          label={
            gettext("Continued past %{minutes} minutes", minutes: @usage["continued_after_minutes"])
          }
          value={@usage["calls_continued"]}
        />
        <% gettext_comment("A figure on the status page: the typical length of a call today.") %>
        <.count
          id="usage-median"
          label={gettext("Typical length")}
          value={
            if @usage["median_minutes"],
              do: median_text(@usage["median_minutes"], @usage["longest_minutes"]),
              else: "–"
          }
        />
      </dl>

      <div id="usage-endings" class="rounded-lg border border-stone-200 bg-white p-5">
        <h3 class="text-sm font-semibold text-stone-950">{gettext("How calls ended")}</h3>
        <dl class="mt-3 grid grid-cols-2 gap-x-6 gap-y-2 text-sm sm:grid-cols-4">
          <div :for={{key, label} <- endings()} id={"usage-ending-#{key}"}>
            <dt class="text-stone-500">{label}</dt>
            <dd class="font-medium text-stone-950">{@usage["endings"][key]}</dd>
          </div>
        </dl>
      </div>

      <div id="usage-pairs" class="rounded-lg border border-stone-200 bg-white p-5">
        <div class="flex items-center gap-1.5">
          <h3 class="text-sm font-semibold text-stone-950">{gettext("Languages spoken")}</h3>
          <%!-- A native disclosure: no script, works by keyboard. --%>
          <details id="usage-pairs-info" class="group relative">
            <summary
              title={gettext("How languages are counted")}
              class="flex size-5 cursor-pointer list-none items-center justify-center rounded-full text-stone-400 transition hover:text-stone-700 group-open:text-teal-700 [&::-webkit-details-marker]:hidden"
            >
              <.icon name="hero-information-circle" class="size-4" />
              <span class="sr-only">{gettext("How languages are counted")}</span>
            </summary>
            <p
              id="usage-pairs-note"
              class="absolute start-0 top-6 z-10 w-64 rounded-md border border-stone-200 bg-white p-3 text-xs leading-5 text-stone-600 shadow-lg"
            >
              {gettext(
                "A language pair shows once it has at least %{min} calls; smaller ones are counted under “other”.",
                min: Randos.Stats.min_published()
              )}
            </p>
          </details>
        </div>
        <ul :if={@usage["language_pairs"] != []} class="mt-3 space-y-1.5 text-sm">
          <li
            :for={pair <- @usage["language_pairs"]}
            id={"usage-pair-#{Enum.join(pair["languages"], "-")}"}
            class="flex justify-between gap-4"
          >
            <span class="text-stone-800">{pair_name(pair["languages"])}</span>
            <span class="font-medium text-stone-950">{pair["calls"]}</span>
          </li>
        </ul>
        <p
          :if={@usage["other_pairs_calls"] > 0}
          id="usage-pairs-other"
          class="mt-2 text-sm text-stone-500"
        >
          {gettext("Other languages: %{calls}", calls: @usage["other_pairs_calls"])}
        </p>
        <p
          :if={@usage["language_pairs"] == [] and @usage["other_pairs_calls"] == 0}
          class="mt-2 text-sm text-stone-500"
        >
          {gettext("No calls yet.")}
        </p>
      </div>

      <p id="usage-privacy" class="text-sm leading-6 text-stone-600">
        {gettext(
          "We count calls, not people: no addresses, no ids, nothing about anyone; only these totals are kept."
        )}
      </p>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, required: true

  defp count(assigns) do
    ~H"""
    <div id={@id} class="rounded-lg border border-stone-200 bg-white p-4">
      <dt class="text-xs font-medium uppercase tracking-[0.12em] text-stone-500">{@label}</dt>
      <dd class="mt-1 text-2xl font-semibold text-stone-950">{@value}</dd>
    </div>
    """
  end

  defp relay_headline("ok"), do: gettext("The relay is working")
  defp relay_headline("degraded"), do: gettext("The relay is partly working")
  defp relay_headline("down"), do: gettext("The relay isn't working")
  defp relay_headline("checking"), do: gettext("Checking the relay…")
  defp relay_headline(_not_configured), do: gettext("No relay is configured")

  defp state_dot("ok"), do: "bg-teal-600"
  defp state_dot("degraded"), do: "bg-red-400"
  defp state_dot("down"), do: "bg-red-600"
  defp state_dot(_checking_or_none), do: "bg-stone-300 motion-safe:animate-pulse"

  defp transport_name("udp"), do: gettext("Over UDP (most calls)")
  defp transport_name("tls"), do: gettext("Over TLS (networks that block UDP)")

  defp endings do
    # A translator comment applies to the next string, so these are bound first.
    gettext_comment("How a call ended: it ran its course normally.")
    finished = gettext("Finished")
    gettext_comment("How a call ended: it was stopped before it connected.")
    canceled = gettext("Canceled")

    [
      {"finished", finished},
      {"not_connected", gettext("Couldn't connect")},
      {"connection_lost", gettext("Connection lost")},
      {"canceled", canceled}
    ]
  end

  defp pair_name([same, same]), do: gettext("%{language} both ways", language: language(same))
  defp pair_name([a, b]), do: "#{language(a)} ↔ #{language(b)}"

  defp language(code), do: ConversationLanguages.name(code)

  defp clock(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _offset} -> Calendar.strftime(at, "%H:%M")
      _invalid -> iso
    end
  end

  # The median is a whole-minute bucket: 0 means under a minute, the
  # snapshot's longest_minutes the catch-all for the longest calls.
  defp median_text(0, _longest) do
    gettext_comment("A call's typical length: less than one minute (min = minutes).")
    gettext("under 1 min")
  end

  defp median_text(longest, longest) do
    gettext_comment("A call's typical length: this many minutes or more (min = minutes).")
    gettext("%{minutes}+ min", minutes: longest)
  end

  defp median_text(minutes, _longest) do
    gettext_comment("A call's typical length in minutes (min = minutes).")
    gettext("%{minutes} min", minutes: minutes)
  end
end
