defmodule Tui.MediaTest do
  use ExUnit.Case, async: true

  import Tui.TestSupport

  alias Tui.Media

  # Runs against the real helper (`cargo build -p randos_media`; `just
  # precommit` builds it first), using its hardware-free sine/null loopback.
  # See test_helper.exs for when these are skipped.
  @moduletag :native

  test "round-trips pings through the real helper over the Port" do
    media = start_supervised!({Media, []})
    assert Media.ping(media) == :pong
    assert Media.ping(media) == :pong
  end

  test "runs a loopback and forwards its events to :notify" do
    media = start_supervised!({Media, notify: self()})
    assert_receive {:media, "ready", %{}}

    assert {:ok, %{"input" => "sine 440 Hz", "output" => "null"}} =
             Media.loopback_start(media, "sine", "null")

    assert {:error, "loopback already running"} = Media.loopback_start(media, "sine", "null")

    assert_receive {:media, "loopback_stats", %{"codec_ms" => 26.5, "input_peak_dbfs" => peak}},
                   2_000

    assert peak > -10
    assert Media.loopback_stop(media) == :ok
  end

  test "async requests reply by message, tagged with the command" do
    media = start_supervised!({Media, []})

    :ok = Media.request_async(media, :ping)
    assert_receive {:media_reply, :ping, {:ok, "pong"}}

    :ok = Media.request_async(media, {:loopback_start, "nope", "null"})

    assert_receive {:media_reply, {:loopback_start, "nope", "null"},
                    {:error, "unknown input" <> _}}
  end

  test "helper errors come back as error replies" do
    media = start_supervised!({Media, []})
    assert {:error, "unknown input" <> _} = Media.loopback_start(media, "nope", "null")
  end

  @tag :capture_log
  test "a crashed helper is restarted by the supervisor, with a fresh helper" do
    children = [{Media, name: :media_restart_test}]
    opts = [strategy: :one_for_one, max_restarts: 1, max_seconds: 5]

    supervisor =
      start_supervised!(%{
        id: :media_restart_supervisor,
        start: {Supervisor, :start_link, [children, opts]},
        type: :supervisor
      })

    first = Process.whereis(:media_restart_test)
    ref = Process.monitor(first)
    kill_helper(first)

    assert_receive {:DOWN, ^ref, :process, ^first, {:helper_exited, _status}}, 2_000
    assert Process.alive?(supervisor)

    second = wait_for_restart(:media_restart_test, first)
    assert Media.ping(second) == :pong
  end

  @tag :capture_log
  test "a missing helper binary means no audio, not a crash" do
    assert :ignore = Media.start_link(helper_path: "/nonexistent/randos_media")
  end
end
