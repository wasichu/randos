defmodule RandosWeb.VoiceProcessor do
  @moduledoc """
  The voice processor calls run (`RANDOS_VOICE_PROCESSOR`; none by default,
  so the mic is sent as it is).

  The processors are listed once, in `assets/js/randos/voice/seam.js`, and
  each is built as its own worklet, `priv/static/assets/js/randos/voice/<name>.js`
  (an esbuild entry in `config/config.exs`). So a name is valid when that
  built file exists, with no second list to keep in step. `check!/0`, run at
  boot, catches a misspelled name, which would otherwise make every call end
  with `audio_failed`: production refuses to start (`:require_built_voice_processor`,
  set in `config/runtime.exs`); development only warns, since its asset
  watchers build the worklets after the server starts.
  """

  require Logger

  @doc "The configured processor's name, or `nil` for none."
  @spec configured() :: String.t() | nil
  def configured, do: Application.get_env(:randos, :voice_processor)

  @doc "Checks the configured processor exists (see the moduledoc)."
  @spec check!() :: :ok
  def check! do
    case configured() do
      nil -> :ok
      name -> if built?(name), do: :ok, else: unknown(name)
    end
  end

  @doc "The processors that are built, by name."
  @spec available() :: [String.t()]
  def available do
    case File.ls(dir()) do
      # Plain names only: in production the digest also writes copies like
      # passthrough-1a2b3c.js (and .gz files).
      {:ok, files} ->
        files |> Enum.map(&Path.rootname(&1, ".js")) |> Enum.filter(&name?/1) |> Enum.sort()

      {:error, _reason} ->
        []
    end
  end

  defp built?(name), do: name?(name) and File.regular?(Path.join(dir(), name <> ".js"))

  defp name?(name), do: name =~ ~r/\A[a-z0-9_]+\z/

  defp dir, do: Application.app_dir(:randos, "priv/static/assets/js/randos/voice")

  defp unknown(name) do
    message =
      "RANDOS_VOICE_PROCESSOR=#{name} names no built voice processor " <>
        "(built: #{Enum.join(available(), ", ")}); every call would end with audio_failed"

    if Application.get_env(:randos, :require_built_voice_processor, false),
      do: raise(message),
      else: Logger.warning(message <> ". If the assets aren't built yet, ignore this.")

    :ok
  end
end
