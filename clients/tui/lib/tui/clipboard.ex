defmodule Tui.Clipboard do
  @moduledoc """
  Copies text (an invitation link, `y`) to the clipboard. The TUI runs on
  the person's own machine, so the system's own command does it where
  there is one: `pbcopy` on macOS, `wl-copy` under Wayland, `xclip` or
  `xsel` under X, its exit status saying whether it worked. Otherwise, and
  always over SSH (the system's command would fill the far machine's
  clipboard), the terminal is asked to (OSC 52, written to `/dev/tty`):
  Ghostty, iTerm2, kitty, WezTerm, Windows Terminal and tmux take it;
  others ignore it, which no program can tell. The result says which way
  it went, so the screen can say what happened.
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
    if env["SSH_TTY"] || env["SSH_CONNECTION"], do: nil, else: local_command(env)
  end

  defp local_command(env) do
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

  # The text from a file on its stdin (sh only redirects; the text never
  # reaches a command line), so its exit status says whether it worked.
  defp through(exe, args, text) do
    path = Path.join(System.tmp_dir!(), "randos-clip-#{System.unique_integer([:positive])}")

    try do
      File.write!(path, text)

      case System.cmd("sh", ["-c", ~S|"$0" "$@" < "$RANDOS_CLIP"|, exe | args],
             env: [{"RANDOS_CLIP", path}],
             stderr_to_stdout: true
           ) do
        {_out, 0} -> {:ok, :system}
        {out, status} -> {:error, {status, String.trim(out)}}
      end
    rescue
      error -> {:error, error}
    after
      File.rm(path)
    end
  end

  defp terminal(text) do
    case File.write("/dev/tty", "\e]52;c;" <> Base.encode64(text) <> "\a") do
      :ok -> {:ok, :terminal}
      {:error, reason} -> {:error, reason}
    end
  end
end
