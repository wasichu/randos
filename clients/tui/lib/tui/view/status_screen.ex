defmodule Tui.View.StatusScreen do
  @moduledoc """
  The server status screen's text (`s` on the idle screen): the same data
  as the website's /status page, from the channel's `status` reply (its
  shape is in `docs/architecture/participant_channel.md`), worded like that
  page. Pure: `text/1` of the model's `status_page`.
  """

  alias Tui.Model

  @doc "The screen's text for `model.status_page` (open)."
  @spec text(Model.t()) :: String.t()
  def text(%{status_page: %{unavailable?: true}}),
    do: "This server has no status page (it's older than the status request)."

  def text(%{status_page: %{snapshot: nil}}), do: "Asking the server…"

  def text(%{status_page: %{snapshot: %{"relay" => relay, "usage" => usage}}} = model) do
    Enum.join([relay_text(relay), usage_text(model, usage), privacy()], "\n\n")
  end

  ## The relay

  defp relay_text(relay) do
    lines =
      [headline(relay["state"]) | Enum.map(relay["transports"] || [], &transport/1)] ++
        checked(relay["checked_at"])

    Enum.join(lines, "\n")
  end

  defp headline("ok"), do: "The relay is working."
  defp headline("degraded"), do: "The relay is partly working."
  defp headline("down"), do: "The relay isn't working."
  defp headline("checking"), do: "Checking the relay…"

  defp headline(_not_configured),
    do: "No relay is configured on this server, so calls here go directly."

  defp transport(%{"transport" => name, "ok" => ok} = transport) do
    result = if ok, do: "working", else: transport["reason"] || "not working"
    "· #{transport_name(name)}: #{result}"
  end

  defp transport_name("udp"), do: "Over UDP (most calls)"
  defp transport_name("tls"), do: "Over TLS (networks that block UDP)"
  defp transport_name(other), do: other

  defp checked(nil), do: []
  defp checked(iso), do: ["Last checked at #{clock(iso)} UTC."]

  ## Today's counts

  defp usage_text(model, usage) do
    endings = usage["endings"] || %{}

    [
      "Today (counting since #{clock(usage["since"])} UTC on #{usage["date"]}):",
      "Calls started: #{usage["calls_started"]}    Connected: #{usage["calls_connected"]}" <>
        "    Continued past 10 minutes: #{usage["calls_continued"]}",
      "Typical length: #{typical_length(usage["median_minutes"])}",
      "How calls ended: finished #{endings["finished"] || 0}, " <>
        "couldn't connect #{endings["not_connected"] || 0}, " <>
        "connection lost #{endings["connection_lost"] || 0}, canceled #{endings["canceled"] || 0}"
    ]
    |> Kernel.++(languages(model, usage))
    |> Kernel.++(nodes(usage["nodes"]))
    |> Enum.join("\n")
  end

  defp typical_length(nil), do: "not enough calls yet"
  defp typical_length(0), do: "under 1 min"
  defp typical_length(30), do: "30 min or more"
  defp typical_length(minutes), do: "#{minutes} min"

  defp languages(model, usage) do
    pairs = usage["language_pairs"] || []
    other = usage["other_pairs_calls"] || 0

    case {pairs, other} do
      {[], 0} ->
        ["Languages spoken: no calls yet"]

      _some ->
        ["Languages spoken:"] ++
          Enum.map(pairs, &"· #{pair_name(model, &1["languages"])}: #{&1["calls"]}") ++
          if(other > 0, do: ["· Other languages: #{other}"], else: [])
    end
  end

  defp pair_name(model, [same, same]), do: "#{Model.language_name(model, same)} both ways"

  defp pair_name(model, [a, b]),
    do: "#{Model.language_name(model, a)} ↔ #{Model.language_name(model, b)}"

  # Only worth saying with more than one server.
  defp nodes(%{"answered" => answered, "total" => total}) when total > 1,
    do: ["Counted across #{answered} of #{total} servers."]

  defp nodes(_one), do: []

  defp privacy do
    "We count calls, not people: no addresses, no ids, nothing about anyone. " <>
      "A language pair shows once it has at least 3 calls; smaller ones count as \"other\"."
  end

  defp clock(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _offset} -> Calendar.strftime(at, "%H:%M")
      _invalid -> iso
    end
  end

  defp clock(_missing), do: "?"
end
