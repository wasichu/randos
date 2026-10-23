defmodule Tui.Config do
  @moduledoc """
  The TUI's settings file: what the person chose last time, so the next
  start picks up where they left off. A small JSON object, kept on this
  computer only (nothing here goes to the server):

      {"speaks": "en", "hears": ["en", "es"], "adult_acknowledged": true,
       "language": "es", "input": "MacBook Pro Microphone", "output": null}

  `language` is the interface's (`Tui.Language`; a file from before it
  had one still loads). `input`/`output` are device names (`null`: the
  system default). Where it
  lives comes from the app config (`:config_path`): the user's config
  directory in an installed build (`~/.config/randos/config.json` on Linux,
  `~/Library/Application Support/randos/config.json` on macOS), `tmp/` in
  development; tests run without one. A missing or unreadable file is just
  no saved settings.
  """

  require Logger

  @doc "The settings saved at `path` (`%{}` if there are none, or no `path`)."
  @spec load(Path.t() | nil) :: map()
  def load(nil), do: %{}

  def load(path) do
    with {:ok, json} <- File.read(path),
         {:ok, %{} = saved} <- Jason.decode(json) do
      saved
    else
      {:error, :enoent} ->
        %{}

      other ->
        Logger.warning("tui: ignoring unreadable settings in #{path}: #{inspect(other)}")
        %{}
    end
  end

  @doc "Saves `settings` at `path` (nothing without a `path`). Failures are logged, not raised."
  @spec save(Path.t() | nil, map()) :: :ok
  def save(nil, _settings), do: :ok

  def save(path, settings) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, Jason.encode_to_iodata!(settings, pretty: true)) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("tui: couldn't save settings to #{path}: #{inspect(reason)}")
        :ok
    end
  end

  @doc """
  The configured path: `{:user_config, file}` resolves under the user's
  config directory; a plain path is used as is; `nil` means no file.
  """
  @spec path(term()) :: Path.t() | nil
  def path({:user_config, file}),
    do: Path.join(:filename.basedir(:user_config, ~c"") |> to_string(), file)

  def path(path) when is_binary(path), do: path
  def path(_none), do: nil
end
