defmodule Tui.Integration.RelayOnlyTest do
  @moduledoc """
  The relay-only obligation, TUI to TUI (`docs/architecture/participant_channel.md`):
  against a server whose only TURN server never answers (`just tui-smoke`
  runs this with RANDOS_TEST_UNREACHABLE_RELAY=1), calls are relay-only and
  must never connect. On one machine, direct (host) candidates would connect
  at once, so a client that ignored the policy fails this test. The same
  scenario runs browser to browser in test/e2e/relay_only_smoke.mjs.
  """
  use ExUnit.Case, async: false

  import Tui.TestSupport

  @moduletag :relay_only
  @moduletag timeout: 60_000

  defp another_call?(%{call: %{"id" => id}}, first), do: id != first
  defp another_call?(_model, _first), do: false

  # Every audio state the app has reported so far.
  defp media_states(app, acc \\ []) do
    receive do
      {:tui_media, ^app, state} -> media_states(app, [state | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "with no reachable relay, two TUIs never connect directly" do
    a = start_audio_tui(:relay_a)
    b = start_audio_tui(:relay_b)
    a_model = await_model(a, &(&1.status == :idle and &1.audio?))
    b_model = await_model(b, &(&1.status == :idle and &1.audio?))

    find(a, a_model, "fr", "ko")
    await_model(a, &(&1.status == :looking))
    find(b, b_model, "ko", "fr")

    # Matched, then the call ends without connecting (the connect timeout,
    # or the helper giving up on the relay). Requeued, the two wait: they
    # aren't matched with each other again for the rematch window. (A new
    # call id also counts, in case a server without that window rematches
    # them in the same step.)
    for app <- [a, b] do
      %{call: %{"id" => first}} = await_model(app, &(&1.status == :connecting and &1.call != nil))
      await_model(app, &(&1.status in [:looking, :idle] or another_call?(&1, first)))
    end

    for app <- [a, b] do
      states = media_states(app)
      assert Enum.any?(states, & &1.relay_only?), "the call wasn't relay-only"

      refute Enum.any?(states, &match?(%{call: %{connection: :connected}}, &1)),
             "connected without the relay: the relay-only policy was ignored"
    end
  end
end
