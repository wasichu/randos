defmodule Mix.Tasks.Tui do
  @shortdoc "Runs the Randos terminal client"

  @moduledoc """
  Runs the text-only Randos client in this terminal:

      mix tui                                   # local dev server
      mix tui --url wss://example.org/participant/websocket
      RANDOS_URL=ws://localhost:4000/participant/websocket mix tui

  Logs go to `tmp/tui.log` (anything printed would garble the screen).
  Calls have no audio yet (`t` on the idle screen tests the mic through the
  media helper, if built): point it at a dev server, not production.
  """
  use Mix.Task

  @default_url "ws://localhost:4000/participant/websocket"

  @impl true
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [url: :string])
    url = opts[:url] || System.get_env("RANDOS_URL") || @default_url

    log_to_file("tmp/tui.log")
    Mix.Task.run("app.start")

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
