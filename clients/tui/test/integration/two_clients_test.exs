defmodule Tui.Integration.TwoClientsTest do
  @moduledoc """
  Two real TUI apps against a running server (RANDOS_URL), over the real
  websocket: match, call, extension vote, and both outcomes. Run with
  `just tui-smoke`, which starts a server with 8 s call segments.
  """
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag timeout: 60_000

  alias ExRatatui.Event
  alias ExRatatui.Runtime
  alias Tui.Model

  defp start_app(id) do
    url = System.get_env("RANDOS_URL") || "ws://localhost:4010/participant/websocket"

    start_supervised!(
      {Tui.App, name: nil, test_mode: {100, 24}, uri: url, test_pid: self()},
      id: id
    )
  end

  defp keys(pid, codes),
    do: Enum.each(codes, &Runtime.inject_event(pid, %Event.Key{code: &1, kind: "press"}))

  # Waits for `pid`'s model to satisfy `fun`.
  defp await(pid, fun, timeout \\ 20_000) do
    receive do
      {:tui_model, ^pid, model} -> if fun.(model), do: model, else: await(pid, fun, timeout)
    after
      timeout -> flunk("timed out waiting for #{inspect(pid)}")
    end
  end

  defp language_index(model, code), do: Enum.find_index(model.languages, &(&1.code == code))

  # Pick the pair on the form, tick 18+, and press Enter.
  defp find(pid, model, speaks, listens) do
    move = fn from, to ->
      List.duplicate("right", Integer.mod(to - from, length(model.languages)))
    end

    keys(
      pid,
      move.(model.speaks, language_index(model, speaks)) ++
        ["tab"] ++
        move.(model.listens, language_index(model, listens)) ++ ["tab", " ", "enter"]
    )
  end

  test "two terminal clients match, reach the vote, and one ends the call" do
    a = start_app(:a)
    b = start_app(:b)

    a_model = await(a, &(&1.status == :idle))
    b_model = await(b, &(&1.status == :idle))

    # A rarely used pair, so a stray browser on the dev server won't interfere.
    find(a, a_model, "id", "tr")
    await(a, &(&1.status == :looking))
    find(b, b_model, "tr", "id")

    await(a, &(&1.status == :in_call))
    await(b, &(&1.status == :in_call))

    # Terminal clients send no offers, so the call stays up until time is up.
    await(a, &(&1.status == :extension_pending))
    await(b, &(&1.status == :extension_pending))

    keys(a, ["n"])

    assert %Model{status: :idle} = await(a, &(&1.status == :idle))
    assert %Model{status: :looking} = await(b, &(&1.status == :looking))
  end
end
