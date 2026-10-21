defmodule Mix.Tasks.Tui do
  @shortdoc "Runs the randos terminal client"

  @moduledoc """
  Runs the randos client in this terminal (`Tui.CLI`, the same as an
  installed `randos`):

      mix tui                                   # local dev server
      mix tui --url wss://randos.slowinput.org/participant/websocket
      RANDOS_URL=ws://localhost:4000/participant/websocket mix tui
      mix tui --check                           # is the audio helper working?

  Logs go to `tmp/tui.log` (anything printed would garble the screen).
  With the media helper built (`cargo build -p randos_media`), calls carry
  audio and `t` on the idle screen tests the mic; without it the client is
  text-only. Calls use the server's STUN/TURN servers, so production works
  too.
  """
  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    case Tui.CLI.main(args) do
      0 -> :ok
      status -> exit({:shutdown, status})
    end
  end
end
