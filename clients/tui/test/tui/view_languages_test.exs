defmodule Tui.ViewLanguagesTest do
  @moduledoc """
  Every screen in every language the TUI has (`Tui.Language.available/0`),
  through the real render path at a normal terminal (80×24) and small
  splits (60×20, 40×20): it draws, no placeholder is left unfilled, and the help
  line still shows how to quit. Translations run longer than English
  (German ~30%) and CJK takes two cells a character.
  """
  use ExUnit.Case, async: true

  use Gettext, backend: Tui.Gettext

  alias Tui.App
  alias Tui.Media.State, as: MediaState
  alias Tui.Model

  @languages [
    %{"code" => "en", "name" => "English (EN)"},
    %{"code" => "de", "name" => "Deutsch (DE)"},
    %{"code" => "ja", "name" => "日本語 (JA)"}
  ]

  @call %{
    "id" => "call-1",
    "call_deadline_unix_ms" => 1_000 + 300_000,
    "extension_duration_seconds" => 600,
    "peer_speaks" => "de",
    "recovering" => true
  }

  @snapshot %{
    "relay" => %{
      "state" => "degraded",
      "checked_at" => "2026-10-21T14:05:00Z",
      "transports" => [
        %{"transport" => "udp", "ok" => true, "reason" => nil},
        %{"transport" => "tls", "ok" => false, "reason" => "tls_failed"}
      ]
    },
    "usage" => %{
      "date" => "2026-10-21",
      "since" => "2026-10-21T09:12:00Z",
      "calls_started" => 12,
      "calls_connected" => 9,
      "calls_continued" => 2,
      "continued_after_minutes" => 10,
      "median_minutes" => 30,
      "longest_minutes" => 30,
      "endings" => %{"finished" => 8, "not_connected" => 2, "connection_lost" => 1},
      "language_pairs" => [%{"languages" => ["en", "de"], "calls" => 5}],
      "other_pairs_calls" => 3,
      "nodes" => %{"answered" => 2, "total" => 3}
    }
  }

  defp model(status, call \\ nil, extra \\ %{}) do
    {model, []} =
      Model.joined(Model.new(1_000), %{
        "state" => %{"status" => status, "webrtc_role" => nil, "error" => nil, "call" => call},
        "languages" => @languages
      })

    model |> Map.put(:hears, ~w(en de ja)) |> Map.merge(extra)
  end

  defp screens do
    [
      {"idle", model("idle", nil, %{error: "The call ended because no microphone was found."})},
      {"looking", model("looking")},
      {"matched", model("connecting", @call)},
      {"in call", model("in_call", @call)},
      {"vote", model("extension_pending", @call)},
      {"voted", model("extension_pending", Map.put(@call, "agreed_to_continue", true))},
      {"status", %{model("idle") | status_page: %{snapshot: @snapshot, info?: false}}},
      {"about these numbers",
       %{model("idle") | status_page: %{snapshot: @snapshot, info?: true}}},
      {"inviting",
       model("inviting", nil, %{
         invitation: %{
           "url" => "https://randos.slowinput.org/join#AAAAAAAAAAAAAAAAAAAAAA",
           "expires_at_unix_ms" => 1_000 + 900_000
         }
       })},
      {"join prompt",
       model("idle", nil, %{join_prompt: "https://randos.slowinput.org/join#AAAA"})},
      {"invitation call",
       model(
         "in_call",
         Map.merge(@call, %{"kind" => "invitation", "peer_speaks_any" => ~w(de ja)})
       )}
    ]
  end

  defp render({width, height}, model) do
    state = %{
      model: model,
      uri: "ws://localhost:4000/participant/websocket",
      media_state: MediaState.new(false)
    }

    terminal = ExRatatui.init_test_terminal(width, height)

    :ok =
      ExRatatui.draw(terminal, App.render(state, %ExRatatui.Frame{width: width, height: height}))

    ExRatatui.get_buffer_content(terminal)
  end

  defp squeeze(text), do: String.replace(text, " ", "")

  for language <- Tui.Language.available(), size <- [{80, 24}, {60, 20}, {40, 20}] do
    @language language
    @size size
    test "#{language} at #{elem(size, 0)}×#{elem(size, 1)}: every screen draws whole" do
      Gettext.with_locale(Tui.Gettext, @language, fn ->
        quit = "q " <> pgettext("key", "quit")

        for {name, model} <- screens() do
          text = render(@size, model)
          refute text =~ "%{", "#{name}: a placeholder left unfilled"
          help = text |> String.split("\n") |> Enum.take(-2) |> Enum.join(" ")
          # Spaces aside: the buffer shows a wide character's second cell as one.
          # (The join prompt takes q as a letter: its way out is esc.)
          way_out = if name == "join prompt", do: "esc", else: quit

          assert squeeze(help) =~ squeeze(way_out),
                 "#{name}: the help line lost #{inspect(way_out)}:\n#{text}"
        end
      end)
    end
  end
end
