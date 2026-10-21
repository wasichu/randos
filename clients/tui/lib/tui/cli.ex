defmodule Tui.CLI do
  @moduledoc """
  The `randos` command: `mix tui` in development, `bin/randos` in a release.

      randos                     # connect to the default server
      randos --url wss://…       # another server (or RANDOS_URL)
      randos --check             # is the audio helper there and working?
      randos --settings          # where your settings are saved, and what's in them
      randos --edit-settings     # open them in $VISUAL / $EDITOR
      randos --reset-settings    # forget them (the next start begins fresh)
      randos --version | --help

  `main/1` returns an exit status; the caller exits with it.
  """

  alias Tui.Media

  @usage """
  Usage: randos [--url URL] [--check] [--settings | --edit-settings | --reset-settings] [--version] [--help]

    --url URL           the randos server (default: #{inspect(Application.compile_env(:tui, :default_url))})
    --check             start the audio helper, ping it, and exit (0 if it answers)
    --settings          show where your settings are saved, and what's in them
    --edit-settings     open your settings in $VISUAL or $EDITOR (vi if neither is set)
    --reset-settings    delete your settings; the next start begins fresh
    --version           print the version

  Settings (your languages, the 18+ confirmation, your mic and speaker) are
  saved as you change them in the app, on this computer only.
  """

  @spec main([String.t()]) :: non_neg_integer()
  def main(args) do
    case OptionParser.parse(args,
           strict: [
             url: :string,
             check: :boolean,
             settings: :boolean,
             edit_settings: :boolean,
             reset_settings: :boolean,
             version: :boolean,
             help: :boolean
           ],
           aliases: [h: :help, v: :version]
         ) do
      {opts, [], []} -> run(opts)
      _invalid -> usage(2)
    end
  end

  # The first flag given picks what to do; with none, run the TUI.
  defp run(opts) do
    case Enum.find(actions(), fn {flag, _action} -> opts[flag] end) do
      {_flag, action} -> action.()
      nil -> start(opts[:url] || System.get_env("RANDOS_URL") || default_url())
    end
  end

  defp actions do
    [
      help: fn -> usage(0) end,
      version: &version/0,
      check: &check/0,
      settings: fn -> show_settings(settings_path()) end,
      edit_settings: fn -> edit_settings(settings_path()) end,
      reset_settings: fn -> reset_settings(settings_path()) end
    ]
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

    {:ok, supervisor} =
      Tui.Supervisor.start_link(uri: url, app: [config: settings_path()] ++ fake_audio())

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

  ## Settings (Tui.Config)

  defp settings_path, do: Tui.Config.path(Application.get_env(:tui, :config_path))

  defp show_settings(nil), do: no_settings_file()

  defp show_settings(path) do
    IO.puts("Settings: #{path}")

    case File.read(path) do
      {:ok, json} ->
        IO.puts(json)

      {:error, :enoent} ->
        IO.puts("(none saved yet: they're saved as you change them in the app)")

      {:error, reason} ->
        IO.puts(:stderr, "can't read them: #{:file.format_error(reason)}")
    end

    0
  end

  # The editor gets this terminal (a Port without stdio pipes), so vi, nano
  # and the like work; "code --wait" style commands are split into words.
  defp edit_settings(nil), do: no_settings_file()

  defp edit_settings(path) do
    unless File.exists?(path), do: Tui.Config.save(path, Tui.Config.load(path))

    [editor | args] =
      OptionParser.split(System.get_env("VISUAL") || System.get_env("EDITOR") || "vi")

    case System.find_executable(editor) do
      nil ->
        IO.puts(:stderr, "editor not found: #{editor} (set VISUAL or EDITOR)")
        1

      executable ->
        port =
          Port.open({:spawn_executable, executable}, [
            :nouse_stdio,
            :exit_status,
            args: args ++ [path]
          ])

        receive do
          {^port, {:exit_status, status}} -> after_edit(path, status)
        end
    end
  end

  defp after_edit(path, 0) do
    case File.read(path)
         |> then(fn
           {:ok, json} -> Jason.decode(json)
           other -> other
         end) do
      {:ok, %{}} ->
        IO.puts("Saved: #{path}")
        0

      _unreadable ->
        IO.puts(
          :stderr,
          "#{path} isn't a JSON object any more; randos will ignore it until it is (or run randos --reset-settings)"
        )

        1
    end
  end

  defp after_edit(_path, status), do: status

  defp reset_settings(nil), do: no_settings_file()

  defp reset_settings(path) do
    case File.rm(path) do
      :ok -> IO.puts("Forgot your settings (#{path}).")
      {:error, :enoent} -> IO.puts("No saved settings (#{path}).")
      {:error, reason} -> IO.puts(:stderr, "can't delete #{path}: #{:file.format_error(reason)}")
    end

    0
  end

  defp no_settings_file do
    IO.puts(:stderr, "this build keeps no settings file")
    1
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
