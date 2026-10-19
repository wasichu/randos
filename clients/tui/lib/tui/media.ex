defmodule Tui.Media do
  @moduledoc """
  Owns the media helper (`randos_media`, a Rust binary) through an Erlang
  Port using `{:packet, 4}` framing. The helper is a separate OS process, so a
  crash in it can never take the TUI down; if it exits, this process stops
  and its supervisor decides what to do.

  The Port protocol is documented in `clients/tui/native/README.md`.
  Stage 0: liveness only (`ping/1`).
  """
  use GenServer

  require Logger

  @doc """
  Options: `:helper_path` (defaults to `default_helper_path/0`), `:name`.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc "Round-trips a `ping` through the helper."
  @spec ping(GenServer.server(), timeout()) :: :pong | {:error, term()}
  def ping(media, timeout \\ 5_000), do: GenServer.call(media, :ping, timeout)

  @doc """
  The helper binary: `RANDOS_MEDIA_BIN` if set, otherwise the workspace's debug
  build (`cargo build -p randos_media` at the repo root). Packaged builds
  (Phase 4.4) will ship it next to the app.
  """
  @spec default_helper_path() :: String.t()
  def default_helper_path do
    System.get_env("RANDOS_MEDIA_BIN") ||
      Path.expand("../../../../target/debug/randos_media", __DIR__)
  end

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :helper_path, default_helper_path())

    if File.regular?(path) do
      port = Port.open({:spawn_executable, path}, [:binary, {:packet, 4}, :exit_status])
      {:ok, %{port: port, waiting: :queue.new()}}
    else
      {:stop, {:helper_not_found, path}}
    end
  end

  @impl true
  def handle_call(:ping, from, state) do
    Port.command(state.port, "ping")
    {:noreply, %{state | waiting: :queue.in(from, state.waiting)}}
  end

  @impl true
  def handle_info({port, {:data, reply}}, %{port: port} = state) do
    case :queue.out(state.waiting) do
      {{:value, from}, waiting} ->
        GenServer.reply(from, decode(reply))
        {:noreply, %{state | waiting: waiting}}

      {:empty, _} ->
        Logger.warning("media helper sent an unexpected message: #{inspect(reply)}")
        {:noreply, state}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    {:stop, {:helper_exited, status}, state}
  end

  defp decode("pong"), do: :pong
  defp decode("error:" <> reason), do: {:error, reason}
  defp decode(other), do: {:error, {:unexpected, other}}
end
