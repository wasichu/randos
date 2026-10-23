defmodule Tui.View do
  @moduledoc """
  The TUI's screens, drawn from `Tui.App`'s state: pure functions of
  `state.model`, `state.media_state`, `state.uri` and `state.config` (the
  settings file's path, or `nil`), so a test can render
  any screen without the app (`Tui.App.render/2` delegates here).
  """

  use Gettext, backend: Tui.Gettext

  alias ExRatatui.Layout
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Widgets.{Block, List, Paragraph, Popup}
  alias Tui.Model
  alias Tui.View.StatusScreen
  alias Tui.Width

  @call_statuses Tui.Model.call_statuses()

  # The audio meters use the website's colours: cyan-600 for you, violet-600
  # for your rando (`assets/js/randos/audio_visualizer.js`).
  @you_color {:rgb, 8, 145, 178}
  @peer_color {:rgb, 124, 58, 237}

  @rtl_terminals "macOS Terminal, iTerm2 3.7+, GNOME Terminal or Konsole (press l for another language)."

  # Narrower than this, You and Devices share one panel.
  @side_by_side_min 90

  @doc "The screen for the app's `state`."
  def render(state, frame) do
    area = %Rect{x: 0, y: 0, width: frame.width, height: frame.height}

    # You and Devices side by side when there's room; on a narrow
    # terminal (a tmux split) the devices go inside the You panel.
    # Not in a right-to-left interface: a terminal that reorders treats a
    # whole row as one paragraph, so two Arabic panels side by side could
    # swap; stacked, each row is one panel between its own borders.
    side_by_side? =
      device_lines(state) != [] and frame.width >= @side_by_side_min and
        not Tui.Terminal.rtl?(state.model.language)

    status_rows = if side_by_side?, do: 2, else: length(status_lines(state, 80, true))
    model = state.model
    # Two rows when the keys don't fit in one (translations run longer),
    # broken between keys, never inside one.
    help_lines = help_lines(help(model) ++ mic_help(state), frame.width)
    help_rows = length(help_lines)

    # The main panel gives way first on a short terminal: the status lines
    # must stay visible.
    [header_area, main_area, status_area, help_area] =
      Layout.split(area, :vertical, [
        {:length, 3},
        {:min, 3},
        {:length, status_rows + 2},
        {:length, help_rows}
      ])

    [
      {header(state), header_area}
      | main_with_meters(state, main_area)
    ] ++
      bottom_panels(state, status_area, side_by_side?) ++
      [
        {%Paragraph{text: Enum.join(help_lines, "\n"), style: %Style{fg: :dark_gray}}, help_area}
      ]
  end

  defp bottom_panels(state, area, true) do
    [status_area, devices_area] =
      Layout.split(area, :horizontal, [{:percentage, 55}, {:percentage, 45}])

    [
      {%Paragraph{
         text: status_text(state, status_area.width - 2, false),
         block: panel(you())
       }, status_area},
      {%Paragraph{
         text:
           state
           |> device_lines()
           |> Enum.map_join(
             "\n",
             &Width.fit(&1, devices_area.width - 2)
           ),
         block: panel(" #{gettext("Devices")} ")
       }, devices_area}
    ]
  end

  defp bottom_panels(state, area, false) do
    [
      {%Paragraph{text: status_text(state, area.width - 2, true), block: panel(you())}, area}
    ]
  end

  # The server status screen (`s` on the idle screen).
  defp main(
         %{connection: :connected, status: :idle, status_page: %{} = page} = model,
         area,
         _extra
       ) do
    screen =
      {%Paragraph{
         text: StatusScreen.text(model),
         block: panel(" #{gettext("Server status")} "),
         wrap: true
       }, area}

    # i: "About these numbers", over the screen.
    about =
      if page[:info?] do
        [
          {%Popup{
             content: %Paragraph{text: StatusScreen.about(), wrap: true},
             block: panel(" #{gettext("About these numbers")} "),
             percent_width: 70,
             fixed_height: 7
           }, area}
        ]
      else
        []
      end

    [screen | about]
  end

  # The idle form is a List so the selection marker keeps rows aligned
  # (Paragraph wrapping trims leading spaces).
  defp main(%{connection: :connected, status: :idle} = model, area, mic_test) do
    [form_area, text_area] = Layout.split(area, :vertical, [{:length, 5}, {:min, 0}])
    ack = if model.adult_acknowledged?, do: "[x]", else: "[ ]"
    [speak, hear] = labels([gettext("I will speak:"), gettext("I'm happy to hear:")])

    gettext_comment("The 18+ box on the form; its [x]/[ ] comes before it.")
    adult = gettext("I'm 18+ and OK with anonymous, unmoderated calls")

    form = %List{
      items: [
        "#{speak}◀ #{Model.language_name(model, model.speaks)} ▶",
        "#{hear}#{hears_row(model)}",
        "#{ack} #{adult}"
      ],
      selected: Enum.find_index([:speaks, :hears, :ack], &(&1 == model.focus)),
      highlight_symbol: "▶ ",
      highlight_style: %Style{fg: :cyan, modifiers: [:bold]},
      block: panel(title(model))
    }

    error =
      if model.error, do: gettext("Error: %{message}", message: model.error) <> "\n\n", else: ""

    [
      {form, form_area},
      {%Paragraph{text: error <> gettext("Press Enter to find a rando.") <> mic_test, wrap: true},
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
          meter(
            gettext("You"),
            Model.language_name(model, model.speaks),
            levels.you,
            @you_color,
            rows,
            %{inner | y: you_y, height: height}
          ) ++
          meter(
            gettext("Your rando"),
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
    audio =
      if model.audio?, do: gettext("Audio on."), else: gettext("Text only (no audio helper).")

    server = server_name(uri)

    connection =
      if model.connection == :connected,
        do: gettext("connected to %{server}", server: server),
        else: gettext("connecting to %{server}…", server: server)

    %Paragraph{text: "#{audio}  #{connection}", block: panel(" randos ")}
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

  # A panel's title, framed by the border: "╭ Find a rando ╮".
  defp title(model), do: " #{title_text(model)} "

  defp title_text(%{connection: :connecting}), do: pgettext("panel title", "Connecting")
  defp title_text(%{status: :idle}), do: pgettext("panel title", "Find a rando")
  defp title_text(%{status: :looking}), do: pgettext("panel title", "Looking")
  defp title_text(%{status: :connecting}), do: pgettext("panel title", "Matched")
  defp title_text(%{status: :in_call}), do: pgettext("panel title", "In call")
  defp title_text(%{status: :extension_pending}), do: pgettext("panel title", "Time is up")
  defp title_text(_model), do: "randos"

  # "English, Español or Français"; past three, a count, as on the website,
  # so a long choice doesn't make a long sentence.
  defp hearing_summary(%{hears: hears} = model) when length(hears) <= 3 do
    case Enum.map(hears, &Model.language_name(model, &1)) do
      [only] ->
        only

      names ->
        gettext_comment("Languages in a list: \"English, Español or Français\".")

        gettext("%{first} or %{last}",
          first: Enum.join(Enum.drop(names, -1), ", "),
          last: Elixir.List.last(names)
        )
    end
  end

  # The count in brackets, so no language has to agree a noun with it.
  defp hearing_summary(%{hears: hears}),
    do: gettext("any of the languages you picked (%{count})", count: length(hears))

  defp main_text(%{connection: :connecting}), do: gettext("Connecting to the server…")

  defp main_text(%{status: :looking} = model) do
    gettext_comment(
      ~S|%{hearing}: one language, "A, B or C", or a count of the languages picked.|
    )

    gettext("Looking for a rando who speaks %{hearing} and wants to hear %{speaking}…",
      hearing: hearing_summary(model),
      speaking: Model.language_name(model, model.speaks)
    )
  end

  defp main_text(%{status: :connecting}), do: gettext("Matched! Starting the call…")

  defp main_text(%{status: :in_call, audio?: true} = model),
    do: gettext("You're in a call.") <> time_left(model, :remaining) <> recovering(model)

  defp main_text(%{status: :in_call} = model) do
    gettext("You're in a call.") <>
      time_left(model, :remaining) <>
      "\n\n" <>
      gettext(
        "This client is running without audio (no media helper): if the peer offers audio (a browser), the call ends and you go back to idle. Two terminal clients can stay in a call to try timers and extension votes."
      )
  end

  # The server counted our `continue` (`call.agreed_to_continue`); one lost
  # in a drop shows the question again.
  defp main_text(%{status: :extension_pending, call: %{"agreed_to_continue" => true}} = model) do
    gettext("Time is up. You agreed to continue, waiting on your rando…") <>
      time_left(model, :to_decide) <>
      "\n\n" <> keys([{"n", pgettext("key", "end")}]) <> recovering(model)
  end

  defp main_text(%{status: :extension_pending} = model) do
    gettext("Time is up.") <>
      " " <>
      continue_question(model.call) <>
      time_left(model, :to_decide) <>
      "\n\n" <>
      keys([{"y", pgettext("key", "continue")}, {"n", pgettext("key", "end")}]) <>
      recovering(model)
  end

  defp main_text(_model), do: ""

  # The server is bringing the call's audio back (`call.recovering`: an ICE
  # restart or a wait, within its recovery budget), as the browser says. If
  # the rando's connection to the server dropped, the Now line already
  # says so, and that's the news.
  defp recovering(%{call: %{"peer_reconnecting" => true}}), do: ""
  defp recovering(%{call: %{"recovering" => true}}), do: "\n\n" <> gettext("Reconnecting audio…")
  defp recovering(_model), do: ""

  # The length comes from the server (`extension_duration_seconds`), never a
  # constant of our own; an older server that doesn't send it gets no number.
  defp continue_question(%{"extension_duration_seconds" => seconds}) when is_integer(seconds),
    do: gettext("Continue for another %{minutes} minutes?", minutes: div(seconds, 60))

  defp continue_question(_call), do: gettext("Continue?")

  # "  4:59 remaining", "  0:12 to decide".
  defp time_left(model, kind) do
    case Model.seconds_left(model) do
      nil ->
        ""

      seconds ->
        time = "#{div(seconds, 60)}:#{pad(rem(seconds, 60))}"
        "  " <> time_left_text(kind, time)
    end
  end

  defp time_left_text(:remaining, time) do
    gettext_comment("The call's time left, as m:ss.")
    gettext("%{time} remaining", time: time)
  end

  defp time_left_text(:to_decide, time) do
    gettext_comment("Time left to vote on continuing the call, as m:ss.")
    gettext("%{time} to decide", time: time)
  end

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  # The help line: each key, then what it does ("q quit"). The keys stay as
  # they are; the words are translated (`pgettext("key", …)`).
  defp keys(hints), do: Enum.map_join(hints, "  ", fn {key, action} -> "#{key} #{action}" end)

  # The hints packed into rows of `width`, at most two: when they need more,
  # hints go from the end, but never how to quit.
  defp help_lines(hints, width) do
    rows = pack(hints, width)

    if length(rows) <= 2 or length(hints) <= 1,
      do: Enum.map(rows, &Width.fit(&1, width)),
      else: help_lines(drop_last_but_quit(hints), width)
  end

  defp pack(hints, width) do
    hints
    |> Enum.map(fn {key, action} -> "#{key} #{action}" end)
    |> Enum.reduce([], fn
      hint, [] ->
        [" " <> hint]

      hint, [line | done] ->
        joined = line <> "  " <> hint
        if Width.of(joined) <= width, do: [joined | done], else: [" " <> hint, line | done]
    end)
    |> Enum.reverse()
  end

  defp drop_last_but_quit(hints) do
    index = hints |> Enum.reverse() |> Enum.find_index(&(elem(&1, 0) != "q"))
    Elixir.List.delete_at(hints, length(hints) - 1 - index)
  end

  defp quit, do: {"q", pgettext("key", "quit")}

  defp help(%{connection: :connecting}), do: [quit()]

  defp help(%{status: :idle, status_page: %{info?: true}}),
    do: [{"i/esc", pgettext("key", "close")}, quit()]

  defp help(%{status: :idle, status_page: %{}}) do
    [
      {"s/esc", pgettext("key", "back")},
      {"r", pgettext("key", "refresh")},
      {"i", pgettext("key", "about these numbers")},
      quit()
    ]
  end

  defp help(%{status: :idle}) do
    gettext_comment("Key help: space ticks or unticks the language under the cursor.")
    check = pgettext("key", "check")

    [
      {"tab/↑↓", pgettext("key", "move")},
      {"←→", pgettext("key", "change")},
      {"space", check},
      {"enter", pgettext("key", "find")},
      {"s", pgettext("key", "status")},
      {"l", pgettext("key", "language")},
      quit()
    ]
  end

  defp help(%{status: :looking}), do: [{"c", pgettext("key", "cancel")}, quit()]

  defp help(%{status: s}) when s in [:connecting, :in_call] do
    gettext_comment("Key help: end this call and find another person to talk to.")
    next = pgettext("key", "next rando")
    [{"e", pgettext("key", "end call")}, {"n", next}, quit()]
  end

  defp help(%{status: :extension_pending, call: %{"agreed_to_continue" => true}}),
    do: [{"n", pgettext("key", "end")}, quit()]

  defp help(%{status: :extension_pending}),
    do: [{"y", pgettext("key", "continue")}, {"n", pgettext("key", "end")}, quit()]

  defp help(_model), do: [quit()]

  defp mic_help(%{media_state: %{available?: false}}), do: []

  defp mic_help(%{model: %{status_page: %{}}}), do: []

  defp mic_help(%{model: %{connection: :connected, status: :idle}, media_state: media}) do
    [{"t", pgettext("key", "mic test")}] ++
      if(media.devices,
        do: [{"i", pgettext("key", "mic")}, {"o", pgettext("key", "speaker")}],
        else: []
      )
  end

  defp mic_help(%{model: %{status: status, audio?: true}, media_state: %{call: call}})
       when status in @call_statuses and is_map(call) do
    if Map.get(call, :muted, false),
      do: [{"m", pgettext("key", "unmute")}],
      else: [{"m", pgettext("key", "mute")}]
  end

  defp mic_help(_state), do: []

  defp extra_text(%{model: %{status: :idle}} = state), do: mic_test_text(state) <> rtl_note(state)

  defp extra_text(_state), do: ""

  # Right-to-left text in a terminal that may not show it right: said in
  # English on purpose (in such a terminal the translation reads reversed).
  defp rtl_note(%{model: %{language: language}} = state) do
    case {Tui.Terminal.rtl?(language), Map.get(state, :bidi, :yes)} do
      {true, :no} ->
        "\n\nThis terminal doesn't show right-to-left text right (it may read reversed). " <>
          @rtl_terminals

      {true, :unknown} ->
        "\n\nRight-to-left text needs a terminal that shows it: " <> @rtl_terminals

      _fine ->
        ""
    end
  end

  # The current state at a glance, like the website's status label and its
  # "Connection:" line (notices, e.g. errors, go to tmp/tui.log; errors also
  # show in the main panel). One line each, never wrapped (a wrapped line
  # pushes the next one out of the box): the connection line drops detail to
  # fit `width`, and anything still too long is cut with "…".
  defp status_text(state, width, devices?) do
    state
    |> status_lines(width, devices?)
    |> Enum.map_join("\n", &Width.fit(&1, width))
  end

  # What you're doing now and the connection (the "You" panel; the server's
  # status is the status screen, s), then (when they share the panel) the mic and
  # speaker once the helper has said what devices there are, on every
  # screen, calls included.
  defp status_lines(%{model: model} = state, width, devices?) do
    [now, connection, _mic, _speaker] = row_labels()
    room = width - Width.of(connection)

    [
      now <> status_label(model),
      connection <> (connection_line(state) |> Enum.find(&(Width.of(&1) <= room)) || "…")
    ] ++ if(devices?, do: device_lines(state), else: [])
  end

  # The You and Devices panels' labels, padded alike so their values line
  # up (in every language: padded to the widest).
  defp row_labels do
    gettext_comment("A row of the You panel: what you're doing now.")
    now = gettext("Now:")
    labels([now, gettext("Connection:"), gettext("Mic:"), gettext("Speaker:")])
  end

  # Labels padded to the widest and a space: "Now:        ", "Connection: ".
  defp labels(labels) do
    widest = labels |> Enum.map(&Width.of/1) |> Enum.max()
    Enum.map(labels, &Width.pad(&1, widest + 1))
  end

  # The values start in the You panel's column (after "Connection: "),
  # side by side or sharing its panel, so the two read as one table.
  defp device_lines(%{media_state: %{available?: true, devices: %{} = devices, choice: choice}}) do
    [_now, _connection, mic, speaker] = row_labels()

    [
      mic <> device_label(choice.input, devices.default_input),
      speaker <> device_label(choice.output, devices.default_output)
    ]
  end

  defp device_lines(_state), do: []

  defp status_label(%{connection: :connecting}), do: gettext("connecting to the server…")
  defp status_label(%{status: :idle}), do: gettext("not looking")
  defp status_label(%{status: :looking}), do: gettext("looking for a rando")
  defp status_label(%{status: :connecting}), do: gettext("matched, preparing the call")
  defp status_label(%{status: :in_call}), do: gettext("in a call")

  defp status_label(%{status: :extension_pending, call: %{"agreed_to_continue" => true}}),
    do: gettext("waiting on your rando")

  defp status_label(%{status: :extension_pending}), do: gettext("time is up: continue?")
  defp status_label(_model), do: "—"

  # Each returns its versions from most to least detailed; `status_text`
  # shows the first that fits.
  # The rando's connection to the server dropped; the call waits for them.
  defp connection_line(%{model: %{call: %{"peer_reconnecting" => true}}}),
    do: [
      gettext("your rando's connection dropped; waiting for them to come back"),
      gettext("rando reconnecting…")
    ]

  defp connection_line(%{model: %{status: status, audio?: true}} = state)
       when status in @call_statuses do
    lines = call_line(state.media_state)

    case state.media_state.call do
      %{muted: true} -> Enum.map(lines, &(gettext("muted") <> " · " <> &1)) ++ [gettext("muted")]
      _call -> lines
    end
  end

  defp connection_line(%{model: %{status: status}})
       when status in @call_statuses,
       do: [gettext("text only (no audio)"), gettext("text only")]

  defp connection_line(_state), do: [gettext("no call")]

  defp call_line(%{call: nil, last_call_error: error}) when is_binary(error), do: [error]
  defp call_line(%{call: nil}), do: [gettext("starting audio…")]
  defp call_line(%{call: %{connection: :disconnected}}), do: [gettext("reconnecting…")]
  defp call_line(%{call: %{connection: :connecting}}), do: [gettext("connecting…")]

  defp call_line(%{call: %{stats: %{} = s}}) do
    connected = connected_via(s["path"])

    gettext_comment(
      "The call's audio levels: what you send and what you hear, in dBFS (keep the unit)."
    )

    levels =
      gettext("%{connected} · you %{you} dBFS · peer %{peer} dBFS",
        connected: connected,
        you: round(s["input_peak_dbfs"]),
        peer: round(s["output_peak_dbfs"])
      )

    gettext_comment("Audio packets this call has sent and received.")

    packets =
      gettext("%{sent} sent / %{received} received",
        sent: s["packets_sent"],
        received: s["packets_received"]
      )

    [levels <> " · " <> packets, levels, connected, gettext("connected")]
  end

  defp call_line(%{call: %{}}), do: [gettext("connected")]

  # The helper's `path`: whether the call goes through a TURN server.
  defp connected_via("relay"), do: gettext("connected via relay")
  defp connected_via("direct"), do: gettext("connected directly")
  defp connected_via(_path), do: gettext("connected")

  # Only while the mic test is on (t shows it, t again hides it): the key
  # itself is in the help line, and the devices are in the You panel.
  defp mic_test_text(%{media_state: %{available?: true, mic_test: %{} = test}}),
    do: "\n\n" <> mic_test_line(test)

  defp mic_test_text(_state), do: ""

  defp device_label(nil, nil), do: gettext("system default")

  defp device_label(nil, default) do
    gettext_comment("A sound device that is the system's default: its name, then (default).")
    gettext("%{device} (default)", device: default)
  end

  defp device_label(name, _default), do: name

  defp mic_test_line(%{phase: :failed, error: error}),
    do: gettext("Mic test failed: %{error}", error: error)

  defp mic_test_line(%{levels: nil}), do: gettext("Mic: opening…")

  # One line: the bars (as the call's "You" meter has them) and the last
  # second's peak. Nothing is played back.
  defp mic_test_line(%{levels: levels, stats: stats}) do
    peak =
      if stats,
        do: "  " <> gettext("peak %{level} dBFS", level: round(stats["input_peak_dbfs"])),
        else: ""

    gettext_comment("The mic test's level meter (bars), its peak, and how to stop it (t).")

    gettext("Mic: %{bars}%{peak}   (t to stop)",
      bars: Enum.map_join(levels, &level_char/1),
      peak: peak
    )
  end

  @level_chars ~w(▁ ▂ ▃ ▄ ▅ ▆ ▇ █)
  defp level_char(level),
    do: Enum.at(@level_chars, round(min(max(level, 0.0), 1.0) * 7))

  defp you, do: " #{gettext("You")} "

  defp panel(title) do
    %Block{title: title, borders: [:all], border_type: :rounded, border_style: %Style{fg: :cyan}}
  end
end
