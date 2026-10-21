defmodule Tui.View do
  @moduledoc """
  The TUI's screens, drawn from `Tui.App`'s state: pure functions of
  `state.model`, `state.media_state`, `state.uri` and `state.config` (the
  settings file's path, or `nil`), so a test can render
  any screen without the app (`Tui.App.render/2` delegates here).
  """

  alias ExRatatui.Layout
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Widgets.{Block, List, Paragraph}
  alias Tui.Model
  alias Tui.View.StatusScreen

  # The audio meters use the website's colours: cyan-600 for you, violet-600
  # for your rando (`assets/js/randos/audio_visualizer.js`).
  @you_color {:rgb, 8, 145, 178}
  @peer_color {:rgb, 124, 58, 237}

  @doc "The screen for the app's `state`."
  def render(state, frame) do
    area = %Rect{x: 0, y: 0, width: frame.width, height: frame.height}

    # The main panel gives way first on a short terminal (a tmux split):
    # the status lines must stay visible.
    [header_area, main_area, status_area, help_area] =
      Layout.split(area, :vertical, [{:length, 3}, {:min, 3}, {:length, 4}, {:length, 1}])

    model = state.model

    [
      {header(state), header_area}
      | main_with_meters(state, main_area)
    ] ++
      [
        {%Paragraph{text: status_text(state, status_area.width - 2), block: panel(" Status ")},
         status_area},
        {%Paragraph{text: " " <> help(model) <> mic_help(state), style: %Style{fg: :dark_gray}},
         help_area}
      ]
  end

  # The server status screen (`s` on the idle screen).
  defp main(%{connection: :connected, status: :idle, status_page: %{}} = model, area, _extra) do
    [
      {%Paragraph{text: StatusScreen.text(model), block: panel(" Server status "), wrap: true},
       area}
    ]
  end

  # The idle form is a List so the selection marker keeps rows aligned
  # (Paragraph wrapping trims leading spaces).
  defp main(%{connection: :connected, status: :idle} = model, area, mic_test) do
    [form_area, text_area] = Layout.split(area, :vertical, [{:length, 5}, {:min, 0}])
    ack = if model.adult_acknowledged?, do: "[x]", else: "[ ]"

    form = %List{
      items: [
        "I will speak:     ◀ #{Model.language_name(model, model.speaks)} ▶",
        "I'm happy to hear: #{hears_row(model)}",
        "#{ack} I'm 18+ and OK with anonymous, unmoderated calls"
      ],
      selected: Enum.find_index([:speaks, :hears, :ack], &(&1 == model.focus)),
      highlight_symbol: "▶ ",
      highlight_style: %Style{fg: :cyan, modifiers: [:bold]},
      block: panel(title(model))
    }

    error = if model.error, do: "Error: #{model.error}\n\n", else: ""

    [
      {form, form_area},
      {%Paragraph{text: error <> "Press Enter to find a rando." <> mic_test, wrap: true},
       text_area}
    ]
  end

  defp main(model, area, extra) do
    [{%Paragraph{text: main_text(model) <> extra, block: panel(title(model)), wrap: true}, area}]
  end

  # The language under the cursor with its box, then every checked code:
  # "◀ [x] Español (ES) ▶  EN ES".
  defp hears_row(model) do
    checked = model.hears |> Enum.map_join(" ", &String.upcase/1)

    case Model.hears_cursor(model) do
      nil ->
        checked

      {code, checked?} ->
        box = if checked?, do: "[x]", else: "[ ]"
        "◀ #{box} #{Model.language_name(model, code)} ▶  #{checked}"
    end
  end

  # During a call with audio, the main panel also shows the two meters (like
  # the website's waveforms) once the helper sends levels, when there's room.
  defp main_with_meters(
         %{
           model: %{status: status, audio?: true} = model,
           media_state: %{call: %{levels: levels}}
         },
         area
       )
       when status in [:in_call, :extension_pending] do
    inner = %Rect{
      x: area.x + 1,
      y: area.y + 1,
      width: max(area.width - 2, 0),
      height: max(area.height - 2, 0)
    }

    # The call text is one line; the vote's is three ("Time is up…", a blank,
    # the keys).
    text_rows = if status == :extension_pending, do: 3, else: 1

    case meter_rows(inner.height - text_rows - 1) do
      nil ->
        main(model, area, "")

      rows ->
        # Bottom of the panel: you, a blank line, your rando.
        height = 1 + 2 * rows
        peer_y = inner.y + inner.height - height
        you_y = peer_y - height - 1

        main(model, area, "") ++
          meter("You", Model.language_name(model, model.speaks), levels.you, @you_color, rows, %{
            inner
            | y: you_y,
              height: height
          }) ++
          meter(
            "Your rando",
            Model.language_name(model, Model.peer_speaks(model)),
            levels.peer,
            @peer_color,
            rows,
            %{inner | y: peer_y, height: height}
          )
    end
  end

  defp main_with_meters(state, area), do: main(state.model, area, extra_text(state))

  # Bar rows on each side of the centre line (up to 3) that fit in `height`:
  # two meters of (label + 2 × rows) and a blank line between them. `nil`
  # if not even one fits, and the meters are left out.
  defp meter_rows(height),
    do: Enum.find(3..1//-1, fn rows -> 2 * (1 + 2 * rows) + 1 <= height end)

  defp meter(label, language, bars, color, rows, %Rect{} = area) do
    label_area = %{area | height: 1}
    bars_area = %{area | y: area.y + 1, height: 2 * rows}

    [
      {%Paragraph{text: "#{label} · #{language}", style: %Style{fg: color, modifiers: [:bold]}},
       label_area},
      {%Paragraph{
         text: bars_text(bars, rows, area.width),
         style: %Style{fg: color},
         alignment: :center
       }, bars_area}
    ]
  end

  # Like the website: the lowest frequencies at the centre, mirrored out to
  # both sides, each bar centred on the middle line. Half-row resolution:
  # "▄" and "▀" are the half steps above and below the line.
  defp bars_text(bars, rows, width) do
    count = min(length(bars), max(div(width, 2), 1))
    {gap, count} = if width >= 4 * count - 1, do: {" ", count}, else: {"", count}
    halves = bars |> Enum.take(count) |> Enum.map(&bar_halves(&1, rows))
    columns = Enum.reverse(halves) ++ halves

    upper =
      for row <- (rows - 1)..0//-1,
          do: Enum.map_join(columns, gap, &cell(&1 - 2 * row, "▄"))

    lower = for row <- 0..(rows - 1), do: Enum.map_join(columns, gap, &cell(&1 - 2 * row, "▀"))
    Enum.join(upper ++ lower, "\n")
  end

  # How many half-rows a bar reaches on each side of the line (at least 1,
  # the website's thin floor; 86% of full height at most, as there).
  defp bar_halves(level, rows),
    do: (level * 0.86 * 2 * rows) |> round() |> max(1) |> min(2 * rows)

  defp cell(fill, _half) when fill >= 2, do: "█"
  defp cell(1, half), do: half
  defp cell(_fill, _half), do: " "

  defp header(%{model: model, uri: uri}) do
    connection = if model.connection == :connected, do: "connected", else: "connecting…"

    %Paragraph{
      text:
        "#{if model.audio?, do: "Audio on", else: "Text only (no audio helper)"}.  #{connection} to #{server_name(uri)}",
      block: panel(" randos ")
    }
  end

  # The server's host (and port, if not the scheme's default): the
  # websocket path is noise to a person.
  defp server_name(uri) do
    case URI.parse(uri) do
      %URI{host: host, port: port, scheme: scheme} when is_binary(host) ->
        if port == URI.default_port(scheme || ""), do: host, else: "#{host}:#{port}"

      _not_a_url ->
        uri
    end
  end

  defp title(%{connection: :connecting}), do: " Connecting "
  defp title(%{status: :idle}), do: " Find a rando "
  defp title(%{status: :looking}), do: " Looking "
  defp title(%{status: :connecting}), do: " Matched "
  defp title(%{status: :in_call}), do: " In call "
  defp title(%{status: :extension_pending}), do: " Time is up "
  defp title(_model), do: " randos "

  # "English, Español or Français"; past three, a count, as on the website,
  # so a long choice doesn't make a long sentence.
  defp hearing_summary(%{hears: hears} = model) when length(hears) <= 3 do
    case Enum.map(hears, &Model.language_name(model, &1)) do
      [only] -> only
      names -> Enum.join(Enum.drop(names, -1), ", ") <> " or " <> Elixir.List.last(names)
    end
  end

  defp hearing_summary(%{hears: hears}), do: "any of the #{length(hears)} languages you picked"

  defp main_text(%{connection: :connecting}), do: "Connecting to the server…"

  defp main_text(%{status: :looking} = model) do
    "Looking for a rando who speaks #{hearing_summary(model)} " <>
      "and wants to hear #{Model.language_name(model, model.speaks)}…"
  end

  defp main_text(%{status: :connecting}), do: "Matched! Starting the call…"

  defp main_text(%{status: :in_call, audio?: true} = model),
    do: "You're in a call.#{time_left(model, " remaining")}"

  defp main_text(%{status: :in_call} = model) do
    "You're in a call.#{time_left(model, " remaining")}\n\n" <>
      "This client has no audio yet: if the peer offers audio (a browser), " <>
      "the call ends and you go back to idle. Two terminal clients can stay " <>
      "in a call to try timers and extension votes."
  end

  defp main_text(%{status: :extension_pending} = model) do
    "Time is up. #{continue_question(model.call)}#{time_left(model, " to decide")}\n\n" <>
      "y: continue    n: end"
  end

  defp main_text(_model), do: ""

  # The length comes from the server (`extension_duration_seconds`), never a
  # constant of our own; an older server that doesn't send it gets no number.
  defp continue_question(%{"extension_duration_seconds" => seconds}) when is_integer(seconds),
    do: "Continue for another #{div(seconds, 60)} minutes?"

  defp continue_question(_call), do: "Continue?"

  defp time_left(model, suffix) do
    case Model.seconds_left(model) do
      nil -> ""
      seconds -> "  #{div(seconds, 60)}:#{pad(rem(seconds, 60))}#{suffix}"
    end
  end

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  defp help(%{connection: :connecting}), do: "q quit"

  defp help(%{status: :idle, status_page: %{}}), do: "s/esc back  r refresh  q quit"

  defp help(%{status: :idle}),
    do: "tab/↑↓ move  ←→ change  space check  enter find  s status  q quit"

  defp help(%{status: :looking}), do: "c cancel  q quit"

  defp help(%{status: s}) when s in [:connecting, :in_call],
    do: "e end call  n next rando  q quit"

  defp help(%{status: :extension_pending}), do: "y continue  n end  q quit"
  defp help(_model), do: "q quit"

  defp mic_help(%{media_state: %{available?: false}}), do: ""

  defp mic_help(%{model: %{status_page: %{}}}), do: ""

  defp mic_help(%{model: %{connection: :connected, status: :idle}, media_state: media}),
    do: "  t mic test" <> if(media.devices, do: "  i/o devices", else: "")

  defp mic_help(%{model: %{status: status, audio?: true}, media_state: %{call: call}})
       when status in [:connecting, :in_call, :extension_pending] and is_map(call),
       do: if(Map.get(call, :muted, false), do: "  m unmute", else: "  m mute")

  defp mic_help(_state), do: ""

  defp extra_text(%{model: %{status: :idle}} = state),
    do: mic_test_text(state) <> settings_text(state)

  defp extra_text(_state), do: ""

  # The current state at a glance, like the website's status label and its
  # "Connection:" line (notices, e.g. errors, go to tmp/tui.log; errors also
  # show in the main panel). One line each, never wrapped (a wrapped line
  # pushes the next one out of the box): the connection line drops detail to
  # fit `width`, and anything still too long is cut with "…".
  defp status_text(%{model: model} = state, width) do
    connection = "Connection: "
    room = width - String.length(connection)

    [
      "Status:     " <> status_label(model),
      connection <> (connection_line(state) |> Enum.find(&(String.length(&1) <= room)) || "…")
    ]
    |> Enum.map_join("\n", &fit(&1, width))
  end

  defp fit(line, width) do
    if String.length(line) <= width,
      do: line,
      else: String.slice(line, 0, max(width - 1, 0)) <> "…"
  end

  defp status_label(%{connection: :connecting}), do: "connecting to the server…"
  defp status_label(%{status: :idle}), do: "not looking"
  defp status_label(%{status: :looking}), do: "looking for a rando"
  defp status_label(%{status: :connecting}), do: "matched, preparing the call"
  defp status_label(%{status: :in_call}), do: "in a call"
  defp status_label(%{status: :extension_pending}), do: "time is up: continue?"
  defp status_label(_model), do: "—"

  # Each returns its versions from most to least detailed; `status_text`
  # shows the first that fits.
  # The rando's connection to the server dropped; the call waits for them.
  defp connection_line(%{model: %{call: %{"peer_reconnecting" => true}}}),
    do: ["your rando's connection dropped; waiting for them to come back", "rando reconnecting…"]

  defp connection_line(%{model: %{status: status, audio?: true}} = state)
       when status in [:connecting, :in_call, :extension_pending] do
    lines = call_line(state.media_state)

    case state.media_state.call do
      %{muted: true} -> Enum.map(lines, &("muted · " <> &1)) ++ ["muted"]
      _call -> lines
    end
  end

  defp connection_line(%{model: %{status: status}})
       when status in [:connecting, :in_call, :extension_pending],
       do: ["text only (no audio)", "text only"]

  defp connection_line(_state), do: ["no call"]

  defp call_line(%{call: nil, last_call_error: error}) when is_binary(error), do: [error]
  defp call_line(%{call: nil}), do: ["starting audio…"]
  defp call_line(%{call: %{connection: :disconnected}}), do: ["reconnecting…"]
  defp call_line(%{call: %{connection: :failed}}), do: ["failed"]
  defp call_line(%{call: %{connection: :connecting}}), do: ["connecting…"]

  defp call_line(%{call: %{stats: %{} = s}}) do
    connected = connected_via(s["path"])

    levels =
      "#{connected} · you #{round(s["input_peak_dbfs"])} dBFS · " <>
        "peer #{round(s["output_peak_dbfs"])} dBFS"

    [
      levels <> " · #{s["packets_sent"]} sent / #{s["packets_received"]} received",
      levels,
      connected,
      "connected"
    ]
  end

  defp call_line(%{call: %{}}), do: ["connected"]

  # The helper's `path`: whether the call goes through a TURN server.
  defp connected_via("relay"), do: "connected via relay"
  defp connected_via("direct"), do: "connected directly"
  defp connected_via(_path), do: "connected"

  # Where the settings live, and how to manage them (Tui.CLI's flags).
  defp settings_text(%{config: path}) when is_binary(path),
    do:
      "\n\nSettings are saved as you go, in #{home_relative(path)} (randos --edit-settings, --reset-settings)."

  defp settings_text(_state), do: ""

  defp home_relative(path) do
    home = System.user_home() || ""

    if home != "" and String.starts_with?(path, home),
      do: "~" <> String.replace_prefix(path, home, ""),
      else: path
  end

  defp mic_test_text(%{media_state: %{available?: false}}), do: ""

  defp mic_test_text(%{media_state: %{mic_test: test} = media}),
    do: "\n\n" <> mic_test_line(test) <> devices_text(media)

  defp devices_text(%{devices: nil}), do: ""

  defp devices_text(%{devices: devices, choice: choice}) do
    "\n\nMic: #{device_label(choice.input, devices.default_input)}" <>
      "\nSpeaker: #{device_label(choice.output, devices.default_output)}"
  end

  defp device_label(nil, nil), do: "system default"
  defp device_label(nil, default), do: "#{default} (system default)"
  defp device_label(name, _default), do: name

  defp mic_test_line(nil), do: "Press t to test your mic (wear headphones)."
  defp mic_test_line(%{phase: :failed, error: error}), do: "Mic test failed: " <> error

  defp mic_test_line(%{phase: phase, stats: nil}) when phase in [:starting, :running],
    do: "Mic test: say something; you should hear yourself…"

  defp mic_test_line(%{phase: :done, stats: nil}), do: "Mic test done."

  defp mic_test_line(%{phase: phase, stats: stats}) do
    prefix = if phase == :done, do: "Mic test done:", else: "Mic test:"

    "#{prefix} ≈#{round(stats["latency_ms"])} ms delay, " <>
      "input peak #{round(stats["input_peak_dbfs"])} dBFS"
  end

  defp panel(title) do
    %Block{title: title, borders: [:all], border_type: :rounded, border_style: %Style{fg: :cyan}}
  end
end
