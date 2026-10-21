defmodule Tui.CLI do
  @moduledoc """
  The `randos` command: `mix tui` in development, `bin/randos` in a release.

      randos                     # connect to the default server
      randos --url wss://…       # another server (or RANDOS_URL)
      randos --check             # is the audio helper there and working?
      randos --version | --help

  `main/1` returns an exit status; the caller exits with it.
  """

  alias Tui.Media

  @usage """
  Usage: randos [--url URL] [--check] [--version] [--help]

    --url URL    the randos server (default: #{inspect(Application.compile_env(:tui, :default_url))})
    --check      start the audio helper, ping it, and exit (0 if it answers)
    --version    print the version
  """

  @spec main([String.t()]) :: non_neg_integer()
  def main(args) do
    case OptionParser.parse(args,
           strict: [url: :string, check: :boolean, version: :boolean, help: :boolean],
           aliases: [h: :help, v: :version]
         ) do
      {opts, [], []} -> run(opts)
      _invalid -> usage(2)
    end
  end

  defp run(opts) do
    cond do
      opts[:help] -> usage(0)
      opts[:version] -> version()
      opts[:check] -> check()
      true -> start(opts[:url] || System.get_env("RANDOS_URL") || default_url())
    end
  end

  defp usage(status) do
    device = if status == 0, do: :stdio, else: :stderr
    IO.write(device, @usage)
    status
  end

  defp version do
    IO.puts("randos #{Application.spec(:tui, :vsn)}")
    0
  end

  # For package managers' tests (and people): the helper starts and answers.
  defp check do
    {:ok, _} = Application.ensure_all_started(:tui)
    path = Media.default_helper_path()

    with true <- File.exists?(path),
         {:ok, media} <- Media.start_link(notify: self()),
         :pong <- Media.ping(media) do
      IO.puts("audio helper: ok (#{path})")
      0
    else
      _failed ->
        IO.puts(:stderr, "audio helper: not working (#{path})")
        1
    end
  end

  defp start(url) do
    {:ok, _} = Application.ensure_all_started(:tui)
    # After the apps start, which add the console log handler: logging to the
    # terminal would draw over the TUI until the next redraw.
    log_to_file(log_path())

    config = Tui.Config.path(Application.get_env(:tui, :config_path))
    {:ok, supervisor} = Tui.Supervisor.start_link(uri: url, app: [config: config] ++ fake_audio())
    app = Process.whereis(Tui.App)
    ref = Process.monitor(app)

    # Quitting stops the app normally (it's :transient, so it stays down);
    # then take Tui.Media and the helper down with it.
    receive do
      {:DOWN, ^ref, :process, ^app, _reason} -> Supervisor.stop(supervisor)
    end

    0
  end

  # RANDOS_FAKE_AUDIO=1: a synthetic tone for the mic and no sound out, for
  # screenshots and demos (`just screenshots`): nothing touches a real mic or
  # speaker. Not for calls with people: they'd hear a beep.
  defp fake_audio do
    if System.get_env("RANDOS_FAKE_AUDIO") == "1",
      do: [call_audio: {"sine", "null"}, mic_test: {"sine", "null"}],
      else: []
  end

  defp default_url, do: Application.fetch_env!(:tui, :default_url)

  defp log_path do
    case Application.fetch_env!(:tui, :log_path) do
      {:user_cache, file} -> Path.join(:filename.basedir(:user_cache, ~c"") |> to_string(), file)
      path -> path
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
