defmodule Mix.Tasks.Tui do
  @shortdoc "Runs the Randos terminal client"

  @moduledoc """
  Runs the text-only Randos client in this terminal:

      mix tui                                   # local dev server
      mix tui --url wss://example.org/participant/websocket
      RANDOS_URL=ws://localhost:4000/participant/websocket mix tui

  Logs go to `tmp/tui.log` (anything printed would garble the screen).
  This client has no audio yet: point it at a dev server, not production.
  """
  use Mix.Task

  @default_url "ws://localhost:4000/participant/websocket"

  @impl true
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [url: :string])
    url = opts[:url] || System.get_env("RANDOS_URL") || @default_url

    log_to_file("tmp/tui.log")
    Mix.Task.run("app.start")

    {:ok, pid} = Tui.App.start_link(name: nil, uri: url)
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
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
