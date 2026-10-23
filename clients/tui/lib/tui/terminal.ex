defmodule Tui.Terminal do
  @moduledoc """
  Whether the terminal shows right-to-left text right: the TUI writes it
  in logical order (as ratatui does), which reads correctly only in a
  terminal that runs the bidi algorithm itself (and joins Arabic letters).
  Researched 2026-10-23 (`docs/architecture/tui_translation.md`): macOS
  Terminal, iTerm2 3.7+, GNOME Terminal (VTE ≥ 0.58) and Konsole do;
  Ghostty, Alacritty, Windows Terminal, WezTerm (by default), kitty and
  VS Code's terminal don't. Known from the environment the terminal sets;
  inside tmux (or anything that hides it) it's unknown.
  """

  @rtl ~w(ar fa ur)

  @doc "Whether `language` is written right to left."
  @spec rtl?(String.t()) :: boolean()
  def rtl?(language), do: language in @rtl

  @doc "`:yes`, `:no` or `:unknown`: does this terminal reorder right-to-left text?"
  @spec bidi(%{optional(String.t()) => String.t()}) :: :yes | :no | :unknown
  def bidi(env \\ System.get_env()) do
    cond do
      env["TERM_PROGRAM"] == "iTerm.app" -> iterm(env["TERM_PROGRAM_VERSION"])
      reorders?(env) -> :yes
      plain?(env) -> :no
      true -> :unknown
    end
  end

  defp reorders?(env),
    do:
      env["TERM_PROGRAM"] == "Apple_Terminal" or vte_version(env["VTE_VERSION"]) >= 5800 or
        env["KONSOLE_VERSION"] != nil

  defp plain?(env),
    do:
      env["TERM_PROGRAM"] in ["ghostty", "vscode", "WezTerm"] or
        Enum.any?(["WT_SESSION", "KITTY_WINDOW_ID", "ALACRITTY_SOCKET"], &env[&1])

  # iTerm2 reorders by default from 3.7.0 (3.6 only behind a setting).
  defp iterm(version) when is_binary(version) do
    case version |> String.split(".") |> Enum.take(2) |> Enum.map(&Integer.parse/1) do
      [{major, _}, {minor, _}] when {major, minor} >= {3, 7} -> :yes
      [{_major, _}, {_minor, _}] -> :no
      _unparsed -> :unknown
    end
  end

  defp iterm(_missing), do: :unknown

  defp vte_version(version) when is_binary(version) do
    case Integer.parse(version) do
      {number, _} -> number
      :error -> 0
    end
  end

  defp vte_version(_missing), do: 0
end
