defmodule Tui.Media.Protocol do
  @moduledoc """
  The media helper's Port messages (JSON bodies inside `{:packet, 4}`
  frames), as pure functions. The contract is the "Port protocol" section of
  `clients/tui/native/README.md`; the Rust side is `src/protocol.rs`.

  Requests carry an integer id and get exactly one reply echoing it. Events
  are unsolicited and carry no id.
  """

  @type id :: pos_integer()
  @type command ::
          :ping
          | {:loopback_start, input :: String.t(), output :: String.t()}
          | :loopback_stop
  @type incoming ::
          {:reply, id() | nil, {:ok, term()} | {:error, String.t()}}
          | {:event, String.t(), map()}
          | {:invalid, binary()}

  @spec encode(id(), command()) :: iodata()
  def encode(id, :ping), do: Jason.encode_to_iodata!(%{id: id, cmd: "ping"})

  def encode(id, {:loopback_start, input, output}),
    do: Jason.encode_to_iodata!(%{id: id, cmd: "loopback_start", in: input, out: output})

  def encode(id, :loopback_stop), do: Jason.encode_to_iodata!(%{id: id, cmd: "loopback_stop"})

  @spec decode(binary()) :: incoming()
  def decode(body) do
    case Jason.decode(body) do
      {:ok, %{"reply" => id, "ok" => ok}} -> {:reply, id, {:ok, ok}}
      {:ok, %{"reply" => id, "error" => error}} -> {:reply, id, {:error, error}}
      {:ok, %{"event" => name} = event} -> {:event, name, Map.delete(event, "event")}
      _ -> {:invalid, body}
    end
  end
end
