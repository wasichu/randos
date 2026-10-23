defmodule Tui.Gettext do
  @moduledoc """
  The TUI's translations (`priv/gettext`), machine-made like the website's
  by the shootout (`tools/translate`, `--catalog tui`). `Tui.Language`
  chooses the locale.
  """
  use Gettext.Backend, otp_app: :tui
end
