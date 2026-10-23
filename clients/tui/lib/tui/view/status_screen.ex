defmodule Tui.View.StatusScreen do
  @moduledoc """
  The server status screen's text (`s` on the idle screen): the same data
  as the website's /status page, from the channel's `status` reply (its
  shape is in `docs/architecture/participant_channel.md`), worded like that
  page. Pure: `text/1` of the model's `status_page`.
  """

  use Gettext, backend: Tui.Gettext

  alias Tui.Model

  @doc "The screen's text for `model.status_page` (open)."
  @spec text(Model.t()) :: String.t()
  def text(%{status_page: %{unavailable?: true}}),
    do: gettext("This server has no status page (it's older than the status request).")

  def text(%{status_page: %{snapshot: nil}}), do: gettext("Asking the server…")

  def text(%{status_page: %{snapshot: %{"relay" => relay, "usage" => usage}}} = model) do
    Enum.join([relay_text(relay), usage_text(model, usage)], "\n\n")
  end

  @doc "What the counts are, and aren't (the pop-up behind i)."
  @spec about() :: String.t()
  def about do
    gettext("We count calls, not people: no addresses, no ids, nothing about anyone.") <>
      "\n\n" <>
      gettext(
        ~S|A language pair shows once it has at least %{count} calls; smaller ones count as "other".|,
        count: 3
      )
  end

  ## The relay

  defp relay_text(relay) do
    lines =
      [headline(relay["state"]) | Enum.map(relay["transports"] || [], &transport/1)] ++
        checked(relay["checked_at"])

    Enum.join(lines, "\n")
  end

  defp headline("ok"), do: gettext("The relay is working.")
  defp headline("degraded"), do: gettext("The relay is partly working.")
  defp headline("down"), do: gettext("The relay isn't working.")
  defp headline("checking"), do: gettext("Checking the relay…")

  defp headline(_not_configured),
    do: gettext("No relay is configured on this server, so calls here go directly.")

  defp transport(%{"transport" => name, "ok" => ok} = transport) do
    gettext_comment("A relay server's state on the status screen: it is working (up).")
    working = gettext("working")
    result = if ok, do: working, else: relay_reason(transport["reason"])
    "· #{transport_name(name)}: #{result}"
  end

  # The server's reason codes (participant_channel.md, `status`), as the
  # website words them (RandosWeb.RelayReasons).
  defp relay_reason("no_answer"), do: gettext("no answer")
  defp relay_reason("couldnt_connect"), do: gettext("couldn't connect")
  defp relay_reason("couldnt_resolve"), do: gettext("couldn't find the server")
  defp relay_reason("connection_closed"), do: gettext("connection closed")
  defp relay_reason("unexpected_reply"), do: gettext("unexpected reply")
  defp relay_reason("no_challenge"), do: gettext("no credentials asked for")
  defp relay_reason("credentials_refused"), do: gettext("credentials refused")
  defp relay_reason("tls_failed"), do: gettext("secure connection failed")
  defp relay_reason("refused"), do: gettext("refused")
  defp relay_reason(_other), do: gettext("not working")

  defp transport_name("udp"), do: gettext("Over UDP (most calls)")
  defp transport_name("tls"), do: gettext("Over TLS (networks that block UDP)")
  defp transport_name(other), do: other

  defp checked(nil), do: []
  defp checked(iso), do: [gettext("Last checked at %{time} UTC.", time: clock(iso))]

  ## Today's counts

  defp usage_text(model, usage) do
    endings = usage["endings"] || %{}

    gettext_comment("How each of today's calls ended, with each kind's count.")

    ended =
      gettext(
        "How calls ended: finished %{finished}, couldn't connect %{not_connected}, connection lost %{lost}, canceled %{canceled}",
        finished: endings["finished"] || 0,
        not_connected: endings["not_connected"] || 0,
        lost: endings["connection_lost"] || 0,
        canceled: endings["canceled"] || 0
      )

    [
      gettext("Today (counting since %{time} UTC on %{date}):",
        time: clock(usage["since"]),
        date: usage["date"]
      ),
      gettext("Calls started: %{started}", started: usage["calls_started"]) <>
        "    " <>
        gettext("Connected: %{connected}", connected: usage["calls_connected"]) <>
        "    #{continued(usage["continued_after_minutes"])}: #{usage["calls_continued"]}",
      gettext("Typical length: %{length}",
        length: typical_length(usage["median_minutes"], usage["longest_minutes"])
      ),
      ended
    ]
    |> Kernel.++(languages(model, usage))
    |> Kernel.++(nodes(usage["nodes"]))
    |> Enum.join("\n")
  end

  # The numbers come with the counts, so a server's call length is never ours
  # to copy (older servers sent neither).
  defp continued(nil), do: gettext("Continued")

  defp continued(minutes) do
    gettext_comment(
      ~S|A count's label: calls whose two people chose to keep talking beyond the first %{minutes} minutes ("past" as in "beyond", not "in the past").|
    )

    gettext("Continued past %{minutes} minutes", minutes: minutes)
  end

  defp typical_length(nil, _longest), do: gettext("not enough calls yet")
  defp typical_length(0, _longest), do: gettext("under 1 min")

  defp typical_length(longest, longest) do
    gettext_comment("A call's typical length, at the longest a call can run (min = minutes).")
    gettext("%{minutes} min or more", minutes: longest)
  end

  defp typical_length(minutes, _longest), do: gettext("%{minutes} min", minutes: minutes)

  defp languages(model, usage) do
    pairs = usage["language_pairs"] || []
    other = usage["other_pairs_calls"] || 0

    case {pairs, other} do
      {[], 0} ->
        [gettext("Languages spoken: no calls yet")]

      _some ->
        [gettext("Languages spoken:")] ++
          Enum.map(pairs, &"· #{pair_name(model, &1["languages"])}: #{&1["calls"]}") ++
          if(other > 0,
            do: ["· " <> gettext("Other languages: %{calls}", calls: other)],
            else: []
          )
    end
  end

  defp pair_name(model, [same, same]) do
    gettext_comment("A language pair where both people spoke the same language.")
    gettext("%{language} both ways", language: Model.language_name(model, same))
  end

  defp pair_name(model, [a, b]),
    do: "#{Model.language_name(model, a)} ↔ #{Model.language_name(model, b)}"

  # Only worth saying with more than one server.
  defp nodes(%{"answered" => answered, "total" => total}) when total > 1,
    do: [
      gettext("Counted across %{answered} of %{total} servers.", answered: answered, total: total)
    ]

  defp nodes(_one), do: []

  defp clock(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _offset} -> Calendar.strftime(at, "%H:%M")
      _invalid -> iso
    end
  end

  defp clock(_missing), do: "?"
end
