defmodule Tui.AppTest do
  use ExUnit.Case, async: true

  import Tui.TestSupport

  alias Tui.App
  alias Tui.Media.State, as: MediaState
  alias Tui.Model

  @languages [
    %{"code" => "en", "name" => "English (EN)"},
    %{"code" => "es", "name" => "Español (ES)"}
  ]

  defp server_state(status, extra \\ %{}) do
    Map.merge(%{"status" => status, "webrtc_role" => nil, "error" => nil, "call" => nil}, extra)
  end

  defp model(status, extra \\ %{}) do
    {model, []} =
      Model.joined(Model.new(1_000), %{
        "state" => server_state(status, extra),
        "languages" => @languages
      })

    model
  end

  defp render_text(model, extra \\ %{}, {width, height} \\ {100, 24}) do
    state =
      Map.merge(
        %{
          model: model,
          uri: "ws://localhost:4000/participant/websocket",
          media_state: MediaState.new(false)
        },
        extra
      )

    terminal = ExRatatui.init_test_terminal(width, height)

    :ok =
      ExRatatui.draw(terminal, App.render(state, %ExRatatui.Frame{width: width, height: height}))

    ExRatatui.get_buffer_content(terminal)
  end

  describe "keyboard help" do
    test "compact footer and full context, including audio controls" do
      extra = %{media_state: MediaState.new(true)}
      text = render_text(model("idle"), extra, {80, 24})
      assert text =~ "? help"
      assert text =~ "enter find"
      refute text =~ "b voice masking"
      full = render_text(model("idle"), Map.put(extra, :help_open?, true), {80, 30})
      assert full =~ "Keyboard shortcuts"
      assert full =~ "b  voice masking"
      assert full =~ "v  invite"
      assert full =~ "?/esc close"
    end

    test "small terminals can scroll through all shortcuts" do
      state = %{model: model("idle"), media_state: MediaState.new(true)}
      limit = Tui.View.help_scroll_limit(state, {45, 14})
      assert limit > 0

      text =
        render_text(
          state.model,
          %{help_open?: true, help_scroll: limit, media_state: state.media_state},
          {45, 14}
        )

      assert text =~ "q  quit"
      assert text =~ "?/esc close"
    end

    test "help keeps its close hint above the voice panel on a short translated terminal" do
      Tui.Language.apply("ar")
      model = %{model("idle") | language: "ar"}
      media = %{MediaState.new(true) | voice_panel?: true}
      text = render_text(model, %{help_open?: true, media_state: media, bidi: :no}, {16, 14})
      assert text =~ "?/esc"
      assert text =~ "q"
    end

    test "help owns keys and paste, clamps on resize, and closes on call transition" do
      {:ok, state} = App.mount(connection: self(), test_mode: {45, 14})

      {:noreply, state} =
        App.handle_info(
          {:randos, {:joined, %{"state" => server_state("idle"), "languages" => @languages}}},
          state
        )

      key = fn code -> %ExRatatui.Event.Key{code: code, kind: "press"} end
      {:noreply, opened} = App.handle_event(key.("?"), state)
      assert opened.help_open?
      assert App.handle_event(key.("v"), opened) == {:noreply, opened}

      assert App.handle_event(%ExRatatui.Event.Paste{content: "a link"}, opened) ==
               {:noreply, opened}

      {:noreply, scrolled} = App.handle_event(key.("down"), opened)
      assert scrolled.help_scroll == 1

      {:noreply, resized} =
        App.handle_event(%ExRatatui.Event.Resize{width: 120, height: 40}, scrolled)

      assert resized.help_scroll == 0
      {:noreply, closed} = App.handle_event(key.("esc"), resized)
      refute closed.help_open?

      {:noreply, changed} =
        App.handle_info({:randos, {:push, "state", server_state("connecting")}}, opened)

      refute changed.help_open?
      assert App.handle_event(key.("q"), opened) == {:stop, opened}
    end
  end

  describe "interface language picker" do
    @tag :tmp_dir
    test "confirming the current inferred locale saves an explicit preference", %{tmp_dir: dir} do
      path = Path.join(dir, "config.json")

      {:ok, state} =
        App.mount(connection: self(), test_mode: {100, 30}, config: path, language: "en")

      state = %{state | model: %{state.model | connection: :connected, status: :idle}}
      key = fn code -> %ExRatatui.Event.Key{code: code, kind: "press"} end
      {:noreply, opened, full_redraw?: true} = App.handle_event(key.("l"), state)
      refute File.exists?(path)
      {:noreply, _closed, full_redraw?: true} = App.handle_event(key.("enter"), opened)
      assert Tui.Config.load(path)["language"] == "en"
    end

    test "physical clear also invalidates the retained frame so unchanged UI is restored" do
      state = %{
        model: model("idle"),
        uri: "ws://localhost:4000/participant/websocket",
        media_state: MediaState.new(false)
      }

      frame = %ExRatatui.Frame{width: 100, height: 30}
      terminal = ExRatatui.init_test_terminal(100, 30)
      widgets = App.render(state, frame)
      :ok = ExRatatui.draw(terminal, widgets)
      expected = ExRatatui.get_buffer_content(terminal)
      :ok = ExRatatui.Native.clear_terminal(terminal)
      refute ExRatatui.get_buffer_content(terminal) == expected
      :ok = ExRatatui.draw(terminal, widgets)
      assert ExRatatui.get_buffer_content(terminal) == expected
    end

    test "closing a multilingual picker restores the previous terminal frame exactly" do
      model = %{
        model("idle")
        | languages: [
            %{code: "en", name: "English (EN)"},
            %{code: "bn", name: "বাংলা (BN)"},
            %{code: "hi", name: "हिन्दी (HI)"},
            %{code: "zh", name: "中文 (ZH)"}
          ]
      }

      state = %{
        model: model,
        uri: "ws://localhost:4000/participant/websocket",
        media_state: MediaState.new(false)
      }

      frame = %ExRatatui.Frame{width: 100, height: 30}
      terminal = ExRatatui.init_test_terminal(100, 30)
      :ok = ExRatatui.draw(terminal, App.render(state, frame))
      before = ExRatatui.get_buffer_content(terminal)
      opened = put_in(state.model.language_picker, "en")
      :ok = ExRatatui.draw(terminal, App.render(opened, frame))
      :ok = ExRatatui.draw(terminal, App.render(state, frame))
      assert ExRatatui.get_buffer_content(terminal) == before
    end

    test "shows every available interface locale and the current language" do
      model = %{model("idle") | language_picker: "en"}
      text = render_text(model, %{}, {100, 30})
      assert text =~ "Interface language"
      assert text =~ "English (EN) ✓"
      assert text =~ "Español (ES)"
      for code <- Tui.Language.available() -- ["en", "es"], do: assert(text =~ code)
      assert text =~ "enter choose"
      assert text =~ "esc/l cancel"
    end

    test "RTL terminals that need reordering can render and scroll the language picker" do
      Tui.Language.apply("ar")
      cursor = List.last(Tui.Language.available())
      model = %{model("idle") | language: "ar", language_picker: cursor}
      text = render_text(model, %{bidi: :no}, {40, 14})
      assert text =~ "▶ #{cursor}"
      assert text =~ "esc/l"
    end

    test "the cursor remains visible near the end of the list in a short terminal" do
      cursor = List.last(Tui.Language.available())
      model = %{model("idle") | language_picker: cursor}
      text = render_text(model, %{}, {40, 14})
      assert text =~ "▶ #{cursor}"
      assert text =~ "esc/l cancel"
    end
  end

  describe "screens" do
    test "connecting" do
      text = render_text(Model.new())
      assert text =~ "Connecting to the server"
      assert text =~ "Text only (no audio helper)"
    end

    test "idle form shows languages, the 18+ box, and key help" do
      text = render_text(model("idle"))
      assert text =~ "I will speak:      ◀ English (EN) ▶"
      # The language under the cursor, then every checked one.
      assert text =~ "I'm happy to hear: ◀ [x] English (EN) ▶  EN"
      assert text =~ "[ ] I'm 18+"
      assert text =~ "enter find"
    end

    test "the server status screen, from a status reply" do
      snapshot = %{
        "relay" => %{
          "state" => "degraded",
          "scope" => "this_node",
          "checked_at" => "2026-10-21T14:05:00Z",
          "transports" => [
            %{"transport" => "udp", "ok" => true, "reason" => nil},
            %{"transport" => "tls", "ok" => false, "reason" => "no_answer"}
          ]
        },
        "usage" => %{
          "date" => "2026-10-21",
          "since" => "2026-10-21T09:12:00Z",
          "calls_started" => 12,
          "calls_connected" => 9,
          "calls_continued" => 2,
          "continued_after_minutes" => 10,
          "median_minutes" => 8,
          "longest_minutes" => 30,
          "endings" => %{
            "finished" => 8,
            "not_connected" => 2,
            "connection_lost" => 1,
            "canceled" => 1
          },
          "language_pairs" => [
            %{"languages" => ["en", "es"], "calls" => 5},
            %{"languages" => ["es", "es"], "calls" => 3}
          ],
          "other_pairs_calls" => 4,
          "nodes" => %{"answered" => 2, "total" => 2}
        }
      }

      {model, [{:push, "status", %{}}]} = Tui.Model.key(model("idle"), "s")
      assert render_text(model) =~ "Asking the server…"

      {model, []} = Tui.Model.reply(model, "status", {:ok, snapshot})
      text = render_text(model, %{}, {100, 30})

      for line <- [
            "Server status",
            "The relay is partly working.",
            "Over UDP (most calls): working",
            "Over TLS (networks that block UDP): no answer",
            "Last checked at 14:05 UTC.",
            "Today (counting since 09:12 UTC on 2026-10-21):",
            "Calls started: 12    Connected: 9    Continued past 10 minutes: 2",
            "Typical length: 8 min",
            "finished 8, couldn't connect 2, connection lost 1, canceled 1",
            "English (EN) ↔ Español (ES): 5",
            "Español (ES) both ways: 3",
            "Other languages: 4",
            "Counted across 2 of 2 servers.",
            "s/esc back  r refresh  i about these numbers  ? help  q quit"
          ],
          do: assert(text =~ line, "missing: #{line}\n\n#{text}")

      # What the counts are and aren't: behind i, in a pop-up; i or esc
      # closes it (esc doesn't leave the screen while it's open).
      refute text =~ "We count calls, not people"
      {about, []} = Tui.Model.key(model, "i")
      about_text = render_text(about, %{}, {100, 30})
      assert about_text =~ "About these numbers"
      assert about_text =~ "We count calls, not people"
      assert about_text =~ "A language pair shows once it has at least 3 calls"
      assert about_text =~ "i/esc close  ? help  q quit"

      for k <- ["i", "esc"] do
        {closed, []} = Tui.Model.key(about, k)
        assert %{status_page: %{info?: false}} = closed
      end

      # The idle form's hints aren't shown over it.
      refute text =~ "enter find"

      {model, []} = Tui.Model.reply(model, "status", {:error, %{"reason" => "invalid_message"}})
      assert render_text(model) =~ "This server has no status page"
    end

    test "right to left: a note where the terminal may not show it, and panels kept apart" do
      arabic = %{model("idle") | language: "ar"}
      assert render_text(arabic, %{bidi: :unknown}) =~ "needs a terminal that shows it"
      refute render_text(arabic, %{bidi: :yes}) =~ "right-to-left"
      refute render_text(arabic, %{bidi: :no}) =~ "right-to-left"
      refute render_text(model("idle"), %{bidi: :unknown}) =~ "right-to-left"

      # Devices stack inside You, never side by side, in a right-to-left interface.
      {media, _} =
        MediaState.reply(
          MediaState.new(true),
          :devices,
          {:ok,
           %{
             "inputs" => ["Mic A"],
             "outputs" => ["Speakers"],
             "default_input" => "Mic A",
             "default_output" => "Speakers"
           }}
        )

      assert render_text(model("idle"), %{media_state: media}, {120, 24}) =~ "Devices"
      refute render_text(arabic, %{media_state: media}, {120, 24}) =~ "Devices"
    end

    test "with the join prompt open, its message is drawn once, in the prompt" do
      model = %{model("idle") | join_prompt: "", message: "paste the whole link you were sent"}
      text = render_text(model)
      assert length(String.split(text, "paste the whole link you were sent")) == 2
    end

    test "the idle screen offers the status screen" do
      refute render_text(model("idle"), %{}, {120, 24}) =~ "s status"
      assert render_text(model("idle"), %{help_open?: true}, {120, 24}) =~ "s  status"
    end

    test "the idle screen doesn't spell out where settings are saved (the docs and --settings do)" do
      text =
        render_text(
          model("idle"),
          %{config: Path.join(System.user_home!(), "cfg/randos.json")},
          {140, 24}
        )

      refute text =~ "Settings are saved"
      refute text =~ "cfg/randos.json"
    end

    test "the mic test: the key in the help line, then its meter, and failure" do
      refute render_text(model("idle")) =~ "t mic test"

      with_media = fn mic_test ->
        render_text(model("idle"), %{
          media_state: %MediaState{available?: true, mic_test: mic_test}
        })
      end

      # No separate hint line: the key is in the help line.
      refute with_media.(nil) =~ "Press t to test your mic"
      refute with_media.(nil) =~ "t mic test"

      assert render_text(model("idle"), %{help_open?: true, media_state: MediaState.new(true)}) =~
               "t  mic test"

      assert with_media.(%{phase: :starting, stats: nil, levels: nil, error: nil}) =~
               "Mic: opening…"

      # A silent meter: bars and the last second's peak, nothing about hearing yourself.
      running = %{phase: :running, stats: nil, levels: [0.0, 0.5, 1.0], error: nil}
      assert with_media.(running) =~ "Mic: ▁▅█   (t to stop)"
      assert with_media.(Map.put(running, :mode, :audition)) =~ "Mic: ▁▅█   (p to stop)"
      refute with_media.(Map.put(running, :mode, :audition)) =~ "(t to stop)"

      assert with_media.(%{running | stats: %{"input_peak_dbfs" => -40.4}}) =~
               "Mic: ▁▅█  peak -40 dBFS   (t to stop)"

      refute with_media.(running) =~ "hear yourself"

      assert with_media.(%{phase: :failed, stats: nil, error: "no mic"}) =~
               "Mic test failed: no mic"
    end

    test "a rando whose connection dropped is shown reconnecting" do
      call = %{"status" => "active", "peer_reconnecting" => true}

      assert render_text(model("in_call", %{"call" => call}), %{}, {140, 24}) =~
               "your rando's connection dropped; waiting for them to come back"
    end

    test "while the server brings the audio back, the call panel says so (the rando's drop wins)" do
      recovering = %{"status" => "active", "recovering" => true}

      text =
        render_text(%{model("in_call", %{"call" => recovering}) | audio?: true}, %{}, {140, 24})

      assert text =~ "Reconnecting audio…"

      both = Map.put(recovering, "peer_reconnecting", true)
      text = render_text(%{model("in_call", %{"call" => both}) | audio?: true}, %{}, {140, 24})
      refute text =~ "Reconnecting audio…"
      assert text =~ "rando"

      healthy = %{"status" => "active", "recovering" => false}

      refute render_text(model("in_call", %{"call" => healthy}), %{}, {140, 24}) =~
               "Reconnecting audio"
    end

    test "looking, matched, in call with a countdown, and the vote" do
      assert render_text(model("looking")) =~ "Looking for a rando"
      # Up to three hearing languages are named; past that, a count.
      assert render_text(%{model("looking") | hears: ["es", "en"]}) =~
               "who speaks Español (ES) or English (EN) and"

      assert render_text(%{model("looking") | hears: ~w(en es fr de)}) =~
               "who speaks any of the languages you picked (4) and"

      assert render_text(model("connecting")) =~ "Matched!"

      in_call =
        model("in_call", %{"call" => %{"status" => "active", "call_deadline_unix_ms" => 91_000}})

      assert render_text(in_call) =~ "1:30 remaining"

      vote =
        model("extension_pending", %{
          "call" => %{
            "status" => "extension_pending",
            "extension_deadline_unix_ms" => 21_000,
            # Not 10, so the number visibly comes from the server.
            "extension_duration_seconds" => 300
          }
        })

      text = render_text(vote)
      assert text =~ "Continue for another 5 minutes?"
      assert text =~ "0:20 to decide"

      # An older server that doesn't send the length: no made-up number.
      older =
        model("extension_pending", %{
          "call" => %{"status" => "extension_pending", "extension_deadline_unix_ms" => 21_000}
        })

      assert render_text(older) =~ "Time is up. Continue?"

      # The server counted our `continue`: say so, and only `n` is left.
      agreed = put_in(vote.call["agreed_to_continue"], true)
      text = render_text(agreed, %{}, {140, 24})
      assert text =~ "You agreed to continue, waiting on your rando…"
      refute text =~ "y continue"
      assert text =~ "n end"
    end

    test "a Devices panel beside You shows the mic and speaker on every screen (inside You when narrow)" do
      {media, []} =
        MediaState.reply(
          MediaState.new(true),
          :devices,
          {:ok,
           %{
             "inputs" => ["Mic A", "Mic B"],
             "outputs" => ["Speakers"],
             "default_input" => "Mic A",
             "default_output" => "Speakers"
           }}
        )

      # Wide enough: a Devices panel beside You.
      text = render_text(model("idle"), %{media_state: media})
      assert text =~ "Devices"
      assert text =~ "Mic:        Mic A (default)"
      assert text =~ "Speaker:    Speakers (default)"
      # The keys break between hints when they need a second row.
      refute text =~ "i mic"
      help = render_text(model("idle"), %{help_open?: true, media_state: media}, {100, 30})
      assert help =~ "i  mic"
      refute text =~ "o speaker"
      assert help =~ "o  speaker"

      # On every screen, so a call shows them too.
      assert render_text(model("in_call"), %{media_state: media}) =~ "Mic:        Mic A"

      chosen = media |> MediaState.cycle_device(:input) |> MediaState.cycle_device(:input)
      assert render_text(model("idle"), %{media_state: chosen}) =~ "Mic:        Mic B"

      # Narrow (a tmux split): no Devices panel; the lines join Status, lined up.
      narrow = render_text(model("idle"), %{media_state: media}, {80, 24})
      refute narrow =~ "Devices"
      assert narrow =~ "Now:        not looking for a rando"
      assert narrow =~ "Mic:        Mic A (default)"
    end

    test "the status panel shows the current state, the connection, and the latest notice" do
      text = render_text(model("idle"))
      assert text =~ "Now:        not looking for a rando"
      assert text =~ "Connection: no call"
      refute text =~ "Last:"

      assert render_text(model("looking")) =~ "Now:        looking for a rando"
      assert render_text(model("in_call")) =~ "Connection: text only (no audio)"

      audio = %{model("in_call") | audio?: true}
      assert render_text(audio) =~ "Connection: starting audio…"

      assert render_text(audio, %{
               media_state: %{
                 MediaState.new(true)
                 | call: %{connection: :connecting, muted: false}
               }
             }) =~ "m mute"

      muted = %{MediaState.new(true) | call: %{connection: :connecting, muted: true}}
      text = render_text(audio, %{media_state: muted})
      assert text =~ "Connection: muted · connecting…"
      assert text =~ "m unmute"
    end

    test "in a call the meters show both sides' bars, mirrored like the website" do
      loud = [0.9, 0.8 | List.duplicate(0.04, 10)]
      quiet = List.duplicate(0.04, 12)

      media = %{
        MediaState.new(true)
        | call: %{
            connection: :connected,
            phase: :active,
            stats: nil,
            levels: %{you: loud, peer: quiet}
          }
      }

      # The server says which language the rando speaks.
      in_call = %{model("in_call") | audio?: true, call: %{"peer_speaks" => "es"}}
      text = render_text(in_call, %{media_state: media}, {80, 30})
      assert text =~ "You · English (EN)"
      assert text =~ "Your rando · Español (ES)"
      # The loud low bars, at the centre: full blocks, mirrored.
      assert text =~ "█ █ █ █"
      # A silent meter is the thin floor line, top and bottom halves.
      assert text =~ "▄ ▄ ▄ ▄"
      assert text =~ "▀ ▀ ▀ ▀"

      # No room on a tiny terminal: the meters step aside.
      refute render_text(%{model("in_call") | audio?: true}, %{media_state: media}, {45, 14}) =~
               "Your rando ·"
    end

    test "on a small terminal (a tmux split) the status lines all stay, shortened" do
      media = %{
        MediaState.new(true)
        | call: %{
            connection: :connected,
            phase: :active,
            stats: %{
              "input_peak_dbfs" => -18.0,
              "output_peak_dbfs" => -22.0,
              "packets_sent" => 1520,
              "packets_received" => 1498
            }
          }
      }

      in_call = %{model("in_call") | audio?: true}
      wide = render_text(in_call, %{media_state: media})
      assert wide =~ "1520 sent / 1498 received"

      relayed = put_in(media.call.stats["path"], "relay")
      assert render_text(in_call, %{media_state: relayed}) =~ "Connection: connected via relay ·"

      small = render_text(in_call, %{media_state: media}, {45, 14})
      assert small =~ "Now:        in a call"
      assert small =~ "Connection: connected"
      refute small =~ "sent /"
      refute small =~ "Last:"
    end
  end

  test "the running app turns keys into protocol pushes and ends calls offering audio" do
    pid =
      start_supervised!(
        {App, name: nil, test_mode: {100, 24}, connection: self(), test_pid: self()}
      )

    send(pid, {:randos, {:joined, %{"state" => server_state("idle"), "languages" => @languages}}})
    assert_receive {:tui_model, ^pid, %Model{status: :idle}}

    # Down to the 18+ box, tick it, find.
    keys(pid, ["tab", "tab", " ", "enter"])

    assert_receive {:"$gen_cast",
                    {:push, "find",
                     %{speaks: "en", hears: ["en"], adult_acknowledged: true, audio: false}}}

    send(pid, {:randos, {:push, "state", server_state("in_call")}})
    assert_receive {:tui_model, ^pid, %Model{status: :in_call}}

    send(pid, {:randos, {:push, "signal", %{"type" => "offer", "call_id" => "call-1"}}})

    assert_receive {:"$gen_cast", {:push, "end_call", %{reason: "audio_unavailable"}}}

    keys(pid, ["n"])
    assert_receive {:"$gen_cast", {:push, "next", %{}}}

    # Quitting mid-call leaves on purpose first (obligation 7).
    ref = Process.monitor(pid)
    keys(pid, ["q"])
    assert_receive {:"$gen_call", from, :leave}
    GenServer.reply(from, :ok)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
  end

  describe "mic test (t)" do
    defp idle_app(media, opts \\ []) do
      app =
        start_supervised!(
          {App,
           [name: nil, test_mode: {100, 24}, connection: self(), test_pid: self(), media: media] ++
             opts}
        )

      send(
        app,
        {:randos, {:joined, %{"state" => server_state("idle"), "languages" => @languages}}}
      )

      assert_receive {:tui_model, ^app, %Model{status: :idle}}
      app
    end

    test "asks a helper that was already running for its devices" do
      # A stand-in for Tui.Media: registered, so the app sees it running.
      Process.register(self(), :app_test_running_media)
      app = idle_app(:app_test_running_media)
      assert_receive {:"$gen_cast", {:request, :devices, ^app}}
    end

    @tag :native
    @tag :capture_log
    test "runs a loopback through Tui.Media and shows its stats" do
      app = idle_app(:app_test_media, mic_test: {"sine", "null"})
      start_supervised!({Tui.Media, name: :app_test_media, notify: app})
      # The helper's "ready" reaches the app before we press t.
      assert_receive {:tui_media, ^app, %{mic_test: nil}}

      keys(app, ["t"])
      assert_receive {:tui_media, ^app, %{mic_test: %{phase: :starting}}}
      # Opening the devices takes a moment under load (precommit, CI: over
      # 2 s once on Linux CI). Only a failing wait takes this long.
      assert_receive {:tui_media, ^app, %{mic_test: %{phase: :running, stats: nil}}}, 5_000

      assert_receive {:tui_media, ^app,
                      %{mic_test: %{phase: :running, stats: %{"codec_ms" => 26.5}}}},
                     5_000

      # The helper dying mid-test is reported, not left showing "running".
      media = Process.whereis(:app_test_media)
      kill_helper(media)

      assert_receive {:tui_media, ^app,
                      %{mic_test: %{phase: :failed, error: "the audio helper restarted"}}},
                     5_000
    end

    @tag :native
    @tag :capture_log
    test "voice preview stays running across keyboard changes and closes on Escape" do
      app = idle_app(:app_test_audition, mic_test: {"sine", "null"}, call_audio: {"sine", "null"})
      start_supervised!({Tui.Media, name: :app_test_audition, notify: app})

      assert_receive {:tui_media, ^app,
                      %{audition_available?: true, endpoints: {"sine", "null"}}},
                     5_000

      keys(app, ["b", "p"])

      assert_receive {:tui_media, ^app, %{mic_test: %{mode: :audition, phase: :running, seq: 1}}},
                     5_000

      keys(app, ["2", "right", "3"])

      assert_receive {:tui_media, ^app,
                      %{
                        voice_family: "tone_pitch",
                        voice_tone: "brighter",
                        mic_test: %{phase: :running, seq: 1}
                      }},
                     5_000

      assert_receive {:tui_media, ^app,
                      %{mic_test: %{phase: :running, stats: %{"voice_ms" => 220.0}}}},
                     5_000

      keys(app, ["1"])

      assert_receive {:tui_media, ^app,
                      %{
                        voice_family: "off",
                        mic_test: %{phase: :running, seq: 1, stats: %{"voice_ms" => +0.0}}
                      }},
                     5_000

      keys(app, ["esc"])
      assert_receive {:tui_media, ^app, %{voice_panel?: false, mic_test: nil}}, 5_000
    end

    test "without a media helper it explains instead of crashing" do
      app = idle_app(nil)
      keys(app, ["t"])

      assert_receive {:tui_media, ^app,
                      %{mic_test: %{phase: :failed, error: "no audio helper" <> _}}}
    end

    test "with the helper down it explains instead of crashing" do
      app = idle_app(:no_such_media)
      keys(app, ["t"])

      assert_receive {:tui_media, ^app,
                      %{mic_test: %{phase: :failed, error: "the audio helper isn't running" <> _}}}
    end
  end

  describe "invitation keys through the app" do
    defp invitation_app do
      app =
        start_supervised!(
          {App,
           [
             name: nil,
             test_mode: {100, 24},
             connection: self(),
             test_pid: self(),
             media: :app_test_no_media
           ]}
        )

      send(
        app,
        {:randos, {:joined, %{"state" => server_state("idle"), "languages" => @languages}}}
      )

      assert_receive {:tui_model, ^app, %Model{status: :idle}}
      app
    end

    test "the join prompt takes q, t, l and question marks as text" do
      app = invitation_app()
      keys(app, ["j", "q", "t", "l", "?"])
      assert_receive {:tui_model, ^app, %Model{join_prompt: "qtl?"}}
      assert Process.alive?(app)
    end

    test "y copies the link and says so on screen" do
      app = invitation_app()
      invitation = %{"url" => "https://randos.example/join#tok", "expires_at_unix_ms" => 9}

      send(
        app,
        {:randos, {:push, "state", server_state("inviting", %{"invitation" => invitation})}}
      )

      assert_receive {:tui_model, ^app, %Model{status: :inviting}}
      keys(app, ["y"])
      assert_receive {:tui_model, ^app, %Model{message: "link copied"}}
    end

    test "a disconnect closes the prompt, so q quits again" do
      app = invitation_app()
      ref = Process.monitor(app)
      keys(app, ["j"])
      assert_receive {:tui_model, ^app, %Model{join_prompt: ""}}
      send(app, {:randos, :disconnected})
      assert_receive {:tui_model, ^app, %Model{connection: :connecting, join_prompt: nil}}
      keys(app, ["q"])
      assert_receive {:DOWN, ^ref, :process, ^app, _reason}
    end
  end

  describe "call audio" do
    # The test plays the server: it feeds the app server pushes, receives
    # the app's channel pushes as casts, and relays signals to a second
    # helper playing the browser.
    @tag :native
    @tag :capture_log
    test "an app with a helper calls a peer helper: signals relayed, media_state reported, audio both ways" do
      app =
        start_supervised!(
          {App,
           name: nil,
           test_mode: {100, 24},
           connection: self(),
           test_pid: self(),
           media: :app_call_media,
           call_audio: {"sine", "null"}},
          id: :app
        )

      start_supervised!({Tui.Media, name: :app_call_media, notify: app}, id: :app_media)
      assert_receive {:tui_media, ^app, %{call: nil}}
      peer = start_supervised!({Tui.Media, name: :peer_media, notify: self()}, id: :peer_media)

      send(
        app,
        {:randos, {:joined, %{"state" => server_state("idle"), "languages" => @languages}}}
      )

      assert_receive {:tui_model, ^app, %Model{status: :idle, audio?: true}}

      # One state push: matched (connecting), with the call's ICE servers.
      call = %{"id" => "call-1", "status" => "connecting", "ice_servers" => []}
      state = server_state("connecting", %{"webrtc_role" => "offerer", "call" => call})
      send(app, {:randos, {:push, "state", state}})

      assert {:ok, _} =
               GenServer.call(
                 peer,
                 {:request, {:call_start, "answerer", [], "sine", "null", false}}
               )

      relay_until(app, peer, System.monotonic_time(:millisecond) + 8_000, %{
        established?: false,
        heard?: false
      })

      # Hanging up stops the helper's call.
      send(app, {:randos, {:push, "state", server_state("idle")}})
      assert_receive {:tui_media, ^app, %{call: nil}}
    end

    defp relay_until(_app, _peer, _deadline, %{established?: true, heard?: true}), do: :ok

    defp relay_until(app, peer, deadline, seen) do
      remaining = deadline - System.monotonic_time(:millisecond)

      receive do
        {:"$gen_cast", {:push, "signal", %{type: "media_state", payload: %{state: :connected}}}} ->
          relay_until(app, peer, deadline, %{seen | established?: true})

        {:"$gen_cast", {:push, "signal", %{type: "media_state"}}} ->
          relay_until(app, peer, deadline, seen)

        {:"$gen_cast", {:push, "signal", %{type: type, payload: payload}}} ->
          :ok = request(peer, {:call_signal, type, payload})
          relay_until(app, peer, deadline, seen)

        {:media, "call_signal", %{"type" => type, "payload" => payload}} ->
          send(app, {:randos, {:push, "signal", %{"type" => type, "payload" => payload}}})
          relay_until(app, peer, deadline, seen)

        {:tui_media, ^app,
         %{call: %{stats: %{"packets_received" => n, "output_peak_dbfs" => db}}}}
        when n > 20 and db > -15 ->
          relay_until(app, peer, deadline, %{seen | heard?: true})

        _other ->
          relay_until(app, peer, deadline, seen)
      after
        max(remaining, 0) -> flunk("call didn't connect with audio in time: #{inspect(seen)}")
      end
    end

    defp request(peer, command) do
      {:ok, true} = GenServer.call(peer, {:request, command})
      :ok
    end
  end
end
