defmodule Tui.Integration.TwoClientsTest do
  @moduledoc """
  Two real TUI apps against a running server (RANDOS_URL), over the real
  websocket: match, call, extension vote, and both outcomes. Run with
  `just tui-smoke`, which starts a server with 8 s call segments.
  """
  use ExUnit.Case, async: false

  import Tui.TestSupport

  @moduletag :integration
  @moduletag timeout: 60_000

  alias Tui.Model

  test "two terminal clients match, reach the vote, and one ends the call" do
    a = start_app(:a)
    b = start_app(:b)

    a_model = await_model(a, &(&1.status == :idle))
    b_model = await_model(b, &(&1.status == :idle))

    # A rarely used pair, so a stray browser on the dev server won't interfere.
    find(a, a_model, "id", "tr")
    await_model(a, &(&1.status == :looking))
    find(b, b_model, "tr", "id")

    await_model(a, &(&1.status == :in_call))
    await_model(b, &(&1.status == :in_call))

    # Terminal clients send no offers, so the call stays up until time is up.
    await_model(a, &(&1.status == :extension_pending))
    await_model(b, &(&1.status == :extension_pending))

    keys(a, ["n"])

    assert %Model{status: :idle} = await_model(a, &(&1.status == :idle))
    assert %Model{status: :looking} = await_model(b, &(&1.status == :looking))
  end
end
