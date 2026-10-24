defmodule Tui.Clipboard do
  @moduledoc """
  Copies text (an invitation link, `y`) to the clipboard. The TUI runs on
  the person's own machine, so the system's own command does it where
  there is one: `pbcopy` on macOS, `wl-copy` under Wayland, `xclip` or
  `xsel` under X. Otherwise the terminal is asked to (OSC 52, written to
  `/dev/tty`): Ghostty, iTerm2, kitty, WezTerm, Windows Terminal and tmux
  (with `set-clipboard on`) take it; others ignore it, which no program
  can tell. The result says which way it went, so the screen can say what
  happened.
  """

  @type result :: {:ok, :system | :terminal} | {:error, term()}

  @doc "Copies `text`: the system's command if there is one, else the terminal."
  @spec copy(String.t()) :: result()
  def copy(text) when is_binary(text) do
    case command(System.get_env()) do
      {exe, args} -> through(exe, args, text)
      nil -> terminal(text)
    end
  end

  @doc false
  def command(env) do
    candidates = [
      {:darwin, "pbcopy", [], nil},
      {:unix, "wl-copy", [], "WAYLAND_DISPLAY"},
      {:unix, "xclip", ["-selection", "clipboard"], "DISPLAY"},
      {:unix, "xsel", ["--clipboard", "--input"], "DISPLAY"}
    ]

    Enum.find_value(candidates, fn {os, name, args, display} ->
      with true <- os?(os),
           true <- display == nil or env[display] not in [nil, ""],
           exe when is_binary(exe) <- System.find_executable(name) do
        {exe, args}
      else
        _not_here -> nil
      end
    end)
  end

  defp os?(:darwin), do: :os.type() == {:unix, :darwin}
  defp os?(:unix), do: match?({:unix, os} when os != :darwin, :os.type())

  # The text on its stdin; closing the port ends it, and the command copies
  # what it read.
  defp through(exe, args, text) do
    port = Port.open({:spawn_executable, exe}, [:binary, args: args])
    true = Port.command(port, text)
    Port.close(port)
    {:ok, :system}
  rescue
    error -> {:error, error}
  end

  defp terminal(text) do
    case File.write("/dev/tty", "\e]52;c;" <> Base.encode64(text) <> "\a") do
      :ok -> {:ok, :terminal}
      {:error, reason} -> {:error, reason}
    end
  end
end
