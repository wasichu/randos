defmodule Tui.Language do
  @moduledoc """
  The TUI's interface language: the one saved in the settings file
  (`Tui.Config`, chosen with `l` on the idle screen), else the
  environment's (`LC_ALL`, `LC_MESSAGES`, `LANG`: `es_ES.UTF-8` is `es`),
  else English. Only languages the TUI has translations for
  (`Tui.Gettext`). The server gets the same code at join, so its own
  words (error messages) come in it too.
  """

  @default "en"
  # What a locale's language part may be called that ours isn't.
  @aliases %{"tl" => "fil"}

  @doc "The languages the TUI can show, English first."
  @spec available() :: [String.t()]
  def available, do: [@default | Enum.sort(Gettext.known_locales(Tui.Gettext) -- [@default])]

  @doc "The language to start in: the saved one, else the environment's, else English."
  @spec resolve(term(), %{optional(String.t()) => String.t()}) :: String.t()
  def resolve(saved, env \\ System.get_env()) do
    cond do
      saved in available() -> saved
      (from_env = from_env(env)) in available() -> from_env
      true -> @default
    end
  end

  @doc "The language an environment's locale names (`nil` for none, `C`, `POSIX`)."
  @spec from_env(%{optional(String.t()) => String.t()}) :: String.t() | nil
  def from_env(env) do
    ["LC_ALL", "LC_MESSAGES", "LANG"]
    |> Enum.map(&env[&1])
    |> Enum.find(&(is_binary(&1) and &1 != ""))
    |> code()
  end

  defp code(nil), do: nil
  defp code(locale) when locale in ["C", "POSIX"], do: nil

  defp code(locale) do
    language = locale |> String.split([".", "@", "_", "-"]) |> hd() |> String.downcase()
    Map.get(@aliases, language, language)
  end

  @doc "Move the picker cursor through available locales, wrapping at either end."
  @spec step(String.t(), -1 | 1) :: String.t()
  def step(code, direction) when direction in [-1, 1] do
    languages = available()

    case Enum.find_index(languages, &(&1 == code)) do
      nil -> @default
      index -> Enum.at(languages, Integer.mod(index + direction, length(languages)))
    end
  end

  @doc "Makes `code` this process's language (the app renders in its own process)."
  @spec apply(String.t()) :: :ok
  def apply(code) do
    Gettext.put_locale(Tui.Gettext, code)
    :ok
  end
end
