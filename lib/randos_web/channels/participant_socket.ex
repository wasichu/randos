defmodule RandosWeb.ParticipantSocket do
  @moduledoc """
  Public, anonymous socket for non-browser clients (the TUI). Browsers use
  LiveView instead. See `docs/architecture/participant_channel.md`.
  """
  use Phoenix.Socket

  channel "participant", RandosWeb.ParticipantChannel

  @impl true
  def connect(_params, socket, _connect_info), do: {:ok, socket}

  # Anonymous: no socket ids, nothing to disconnect by identity.
  @impl true
  def id(_socket), do: nil
end
