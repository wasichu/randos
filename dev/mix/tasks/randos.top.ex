defmodule Mix.Tasks.Randos.Top do
  @shortdoc "Runs the dev server with the terminal monitor (dev only)"

  @moduledoc """
  Starts the dev server and `RandosDev.Monitor` in the same VM:

      mix randos.top        # or: just top

  The monitor owns the terminal, so asset watchers are off (run
  `mix assets.build` first if assets changed) and logs go to `tmp/top.log`.
  The server still answers on :4000, so browsers can connect and you watch
  them in the monitor. Press `q` to quit (stops the server too).
  """
  use Mix.Task

  @requirements ["app.config"]

  @impl true
  def run(_args) do
    endpoint = Application.get_env(:randos, RandosWeb.Endpoint, [])
    Application.put_env(:randos, RandosWeb.Endpoint, Keyword.put(endpoint, :watchers, []))
    Application.put_env(:phoenix, :serve_endpoints, true, persistent: true)

    log_to_file("tmp/top.log")
    Mix.Task.run("app.start")
    # Starting the app re-installs Logger's console handler; drop it again.
    remove_console_handler()

    {:ok, pid} = RandosDev.Monitor.start_link(name: nil)
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    end
  end

  # Anything written to stdout would garble the TUI.
  defp log_to_file(path) do
    File.mkdir_p!(Path.dirname(path))
    remove_console_handler()

    :ok =
      :logger.add_handler(:randos_top, :logger_std_h, %{
        config: %{file: String.to_charlist(path)},
        formatter: Logger.Formatter.new(colors: [enabled: false])
      })
  end

  defp remove_console_handler do
    case :logger.remove_handler(:default) do
      :ok -> :ok
      {:error, {:not_found, :default}} -> :ok
    end
  end
end
