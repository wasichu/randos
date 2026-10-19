defmodule Tui.Supervisor do
  @moduledoc """
  The TUI's process tree: `Tui.Media` (the audio helper's owner) and
  `Tui.App` (which starts its own `Tui.Connection`).

  `one_for_one`: a crashed helper is restarted without touching the UI or
  the call's channel. If it crash-loops past `max_restarts`, the supervisor
  gives up and the TUI exits, since a call without audio isn't a call.
  `Tui.App` is `:transient`, so quitting (`q`) doesn't restart it.
  """
  use Supervisor

  @doc """
  Options: `:uri` (participant websocket URL), `:name`, and `:app` (extra
  `Tui.App` options; tests pass `test_mode` and `connection`).
  """
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @impl true
  def init(opts) do
    children = [
      {Tui.Media, name: Tui.Media, notify: Tui.App},
      {Tui.App,
       [name: Tui.App, uri: Keyword.fetch!(opts, :uri), media: Tui.Media] ++
         Keyword.get(opts, :app, [])}
    ]

    Supervisor.init(children, strategy: :one_for_one, max_restarts: 3, max_seconds: 10)
  end
end
