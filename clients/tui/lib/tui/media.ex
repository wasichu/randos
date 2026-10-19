defmodule Tui.Media do
  @moduledoc """
  Owns the media helper (`randos_media`, a Rust binary) through an Erlang
  Port. The helper is a separate OS process, so a crash in it can never take
  the TUI down. Messages are `Tui.Media.Protocol`; the contract is documented
  in `clients/tui/native/README.md`.

  Two failure modes, two outcomes:

    * helper binary missing: `init/1` returns `:ignore`, so the TUI runs
      text-only and the supervisor doesn't restart-loop
    * helper exits: this process stops with `{:helper_exited, status}`, and
      its supervisor restarts it (a fresh helper)

  Helper events are sent to the `:notify` process as
  `{:media, name, payload}`, e.g. `{:media, "loopback_stats", %{...}}`.
  Every (re)start first sends `{:media, "ready", %{}}`: a fresh helper, so
  any media state the receiver holds is stale.
  """
  use GenServer

  require Logger

  alias Tui.Media.Protocol

  @doc """
  Options:

    * `:helper_path` — defaults to `default_helper_path/0`
    * `:notify` — pid or registered name that receives helper events
    * `:name`
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc "Round-trips a ping through the helper."
  @spec ping(GenServer.server(), timeout()) :: :pong | {:error, term()}
  def ping(media, timeout \\ 5_000) do
    case request(media, :ping, timeout) do
      {:ok, "pong"} -> :pong
      other -> {:error, other}
    end
  end

  @doc """
  Starts the mic → Opus → speaker loopback. `input` is `"device"` or
  `"sine"`; `output` is `"device"`, `"null"`, or `"wav:PATH"`. Replies with
  what the helper opened; stats then arrive as `loopback_stats` events.
  """
  @spec loopback_start(GenServer.server(), String.t(), String.t()) ::
          {:ok, map()} | {:error, String.t()}
  def loopback_start(media, input, output),
    do: request(media, {:loopback_start, input, output}, 5_000)

  @spec loopback_stop(GenServer.server()) :: :ok | {:error, String.t()}
  def loopback_stop(media) do
    with {:ok, true} <- request(media, :loopback_stop, 5_000), do: :ok
  end

  defp request(media, command, timeout), do: GenServer.call(media, {:request, command}, timeout)

  @doc """
  Sends a request without waiting (what `Tui.App` uses, so the UI never
  blocks on a device opening). The reply arrives at the caller as
  `{:media_reply, command, result}`. If the helper dies first there is no
  reply; the restarted server's `"ready"` event says so.
  """
  @spec request_async(GenServer.server(), Protocol.command()) :: :ok
  def request_async(media, command), do: GenServer.cast(media, {:request, command, self()})

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
      notify = Keyword.get(opts, :notify)
      notify(notify, {:media, "ready", %{}})
      {:ok, %{port: port, next_id: 1, pending: %{}, notify: notify}}
    else
      Logger.warning("media helper not found at #{path}; running without audio")
      :ignore
    end
  end

  @impl true
  def handle_call({:request, command}, from, state) do
    id = state.next_id
    Port.command(state.port, Protocol.encode(id, command))
    {:noreply, %{state | next_id: id + 1, pending: Map.put(state.pending, id, from)}}
  end

  @impl true
  def handle_cast({:request, command, reply_to}, state) do
    id = state.next_id
    Port.command(state.port, Protocol.encode(id, command))
    pending = Map.put(state.pending, id, {:async, reply_to, command})
    {:noreply, %{state | next_id: id + 1, pending: pending}}
  end

  @impl true
  def handle_info({port, {:data, body}}, %{port: port} = state) do
    {:noreply, handle_incoming(Protocol.decode(body), state)}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    {:stop, {:helper_exited, status}, state}
  end

  defp handle_incoming({:reply, id, result}, state) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        Logger.warning(
          "media helper replied to unknown request #{inspect(id)}: #{inspect(result)}"
        )

        state

      {{:async, reply_to, command}, pending} ->
        send(reply_to, {:media_reply, command, result})
        %{state | pending: pending}

      {from, pending} ->
        GenServer.reply(from, result)
        %{state | pending: pending}
    end
  end

  defp handle_incoming({:event, name, payload}, state) do
    notify(state.notify, {:media, name, payload})
    state
  end

  defp handle_incoming({:invalid, body}, state) do
    Logger.warning("media helper sent an invalid message: #{inspect(body)}")
    state
  end

  defp notify(nil, _message), do: :ok
  defp notify(pid, message) when is_pid(pid), do: send(pid, message)

  # A registered name may be briefly absent (its process restarting).
  defp notify(name, message) when is_atom(name) do
    if pid = Process.whereis(name), do: send(pid, message)
    :ok
  end
end
