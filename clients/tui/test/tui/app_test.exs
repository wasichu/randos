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

  describe "screens" do
    test "connecting" do
      text = render_text(Model.new())
      assert text =~ "Connecting to the server"
      assert text =~ "Text only (no audio helper)"
    end

    test "idle form shows languages, the 18+ box, and key help" do
      text = render_text(model("idle"))
      assert text =~ "I will speak:     ◀ English (EN) ▶"
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
            %{"transport" => "tls", "ok" => false, "reason" => "no answer"}
          ]
        },
        "usage" => %{
          "date" => "2026-10-21",
          "since" => "2026-10-21T09:12:00Z",
          "calls_started" => 12,
          "calls_connected" => 9,
          "calls_continued" => 2,
          "median_minutes" => 8,
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
            "s/esc back  r refresh  i about these numbers  q quit"
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
      assert about_text =~ "i/esc close  q quit"

      for k <- ["i", "esc"] do
        {closed, []} = Tui.Model.key(about, k)
        assert %{status_page: %{info?: false}} = closed
      end

      # The idle form's hints aren't shown over it.
      refute text =~ "enter find"

      {model, []} = Tui.Model.reply(model, "status", {:error, %{"reason" => "invalid_message"}})
      assert render_text(model) =~ "This server has no status page"
    end

    test "the idle screen offers the status screen" do
      assert render_text(model("idle"), %{}, {120, 24}) =~ "s status"
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
      assert with_media.(nil) =~ "t mic test"

      assert with_media.(%{phase: :starting, stats: nil, levels: nil, error: nil}) =~
               "Mic: opening…"

      # A silent meter: bars and the last second's peak, nothing about hearing yourself.
      running = %{phase: :running, stats: nil, levels: [0.0, 0.5, 1.0], error: nil}
      assert with_media.(running) =~ "Mic: ▁▅█   (t to stop)"

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
               "who speaks any of the 4 languages you picked and"

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
      assert text =~ "i mic  o speaker"

      # On every screen, so a call shows them too.
      assert render_text(model("in_call"), %{media_state: media}) =~ "Mic:        Mic A"

      chosen = media |> MediaState.cycle_device(:input) |> MediaState.cycle_device(:input)
      assert render_text(model("idle"), %{media_state: chosen}) =~ "Mic:        Mic B"

      # Narrow (a tmux split): no Devices panel; the lines join Status, lined up.
      narrow = render_text(model("idle"), %{media_state: media}, {80, 24})
      refute narrow =~ "Devices"
      assert narrow =~ "Now:        not looking"
      assert narrow =~ "Mic:        Mic A (default)"
    end

    test "the status panel shows the current state, the connection, and the latest notice" do
      text = render_text(model("idle"))
      assert text =~ "Now:        not looking"
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
