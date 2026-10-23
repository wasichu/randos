defmodule Tui.Integration.LanguageTest do
  @moduledoc """
  The TUI's language reaches the server (the `locale` join param), so the
  server's own words come in it: here the refusal of a `find` without the
  18+ acknowledgment, in Spanish. Against a running server (`just tui-smoke`).
  """
  use ExUnit.Case, async: false

  import Tui.TestSupport

  @moduletag :integration
  @moduletag timeout: 30_000

  test "a TUI in Spanish gets the server's error message in Spanish" do
    app = start_app(:spanish_tui, {100, 24}, language: "es")
    await_model(app, &(&1.status == :idle))

    # Enter without ticking 18+: the server refuses, in the TUI's language.
    keys(app, ["enter"])
    %{error: error} = await_model(app, &(&1.error != nil))

    # Not English: the server used the locale. (Its Spanish is the
    # server's to choose and may change; the TUI never copies it.)
    english = "Accept the 18+ acknowledgment before looking for a rando."
    assert is_binary(error) and error != english
    assert error =~ "18+"
  end
end
