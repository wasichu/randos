defmodule Mix.Tasks.Tui do
  @shortdoc "Runs the randos terminal client"

  @moduledoc """
  Runs the text-only randos client in this terminal:

      mix tui                                   # local dev server
      mix tui --url wss://example.org/participant/websocket
      RANDOS_URL=ws://localhost:4000/participant/websocket mix tui

  Logs go to `tmp/tui.log` (anything printed would garble the screen).
  With the media helper built (`cargo build -p randos_media`), calls carry
  audio and `t` on the idle screen tests the mic; without it the client is
  text-only. Calls use the server's STUN/TURN servers, so production works
  too: `--url wss://randos.slowinput.org/participant/websocket`.
  """
  use Mix.Task

  @default_url "ws://localhost:4000/participant/websocket"

  @impl true
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [url: :string])
    url = opts[:url] || System.get_env("RANDOS_URL") || @default_url

    # After app.start, which re-adds the console log handler: logging to the
    # terminal would draw over the TUI until the next redraw.
    Mix.Task.run("app.start")
    log_to_file("tmp/tui.log")

    {:ok, supervisor} = Tui.Supervisor.start_link(uri: url)
    app = Process.whereis(Tui.App)
    ref = Process.monitor(app)

    # Quitting stops the app normally (it's :transient, so it stays down);
    # then take Tui.Media and the helper down with it.
    receive do
      {:DOWN, ^ref, :process, ^app, _reason} -> Supervisor.stop(supervisor)
    end
  end

  defp log_to_file(path) do
    File.mkdir_p!(Path.dirname(path))
    _ = :logger.remove_handler(:default)

    :ok =
      :logger.add_handler(:tui_file, :logger_std_h, %{
        config: %{file: String.to_charlist(path)},
        formatter: Logger.Formatter.new(colors: [enabled: false])
      })
  end
end
