defmodule RandosWeb.RelayHealth do
  @moduledoc """
  Whether the TURN relay works, for the public status page: every
  #{div(300_000, 60_000)} minutes (and at start), a real TURN allocation over UDP (`turn:`)
  and over TLS (`turns:`) with fresh credentials from
  `RandosWeb.IceServers`, released at once (`RandosWeb.RelayHealth.Turn`).

  Fly stops the machine when it's idle, so a status page opened after a
  while finds an old result: `refresh_if_stale/1` starts a check without
  waiting for it, and the result is announced on `topic/0`.

  Results say only ok or a short reason ("no answer", "credentials
  refused"): never an address, a credential, or the secret. Without a TURN
  server (development, tests) the relay is `:not_configured` and nothing is
  ever sent.
  """

  use GenServer

  require Logger

  alias RandosWeb.IceServers
  alias RandosWeb.RelayHealth.Turn

  @interval 300_000
  @topic "relay_health"

  @typedoc "One transport's last result."
  @type result :: %{ok: boolean(), reason: String.t() | nil}

  @typedoc """
  `:configured` (whether there's a relay to check), `:checking` (a check is
  running), `:checked_at` (UTC, or nil before the first), and `:results`
  (per transport, only those configured).
  """
  @type status :: %{
          configured: boolean(),
          checking: boolean(),
          checked_at: DateTime.t() | nil,
          results: %{optional(:udp | :tls) => result()}
        }

  @doc """
  Options: `:name`, `:pubsub`, `:interval` (ms), `:servers` (a 0-arity fun
  returning the ICE servers; default `IceServers.list/0`), `:turn` (options
  for `Turn.check/2`).
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "The topic results are announced on (`{:relay_health, status}`)."
  def topic, do: @topic

  @doc "The latest status."
  @spec status(GenServer.server()) :: status()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc "Starts a check unless one ran within the interval (or is running). Doesn't wait."
  @spec refresh_if_stale(GenServer.server()) :: :ok
  def refresh_if_stale(server \\ __MODULE__), do: GenServer.cast(server, :refresh_if_stale)

  @doc "The check interval, in ms."
  def interval, do: @interval

  ## Server

  @impl true
  def init(opts) do
    state = %{
      pubsub: Keyword.get(opts, :pubsub, Randos.PubSub),
      interval: Keyword.get(opts, :interval, @interval),
      servers: Keyword.get(opts, :servers, &IceServers.list/0),
      turn: Keyword.get(opts, :turn, []),
      task: nil,
      status: %{configured: false, checking: false, checked_at: nil, results: %{}}
    }

    {:ok, state, {:continue, :check}}
  end

  @impl true
  def handle_continue(:check, state), do: {:noreply, start_check(state)}

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  @impl true
  def handle_cast(:refresh_if_stale, state) do
    {:noreply, if(stale?(state), do: start_check(state), else: state)}
  end

  @impl true
  def handle_info(:tick, state), do: {:noreply, start_check(state)}

  def handle_info({ref, results}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    status = %{
      configured: results != %{},
      checking: false,
      checked_at: DateTime.utc_now() |> DateTime.truncate(:second),
      results: results
    }

    log(results)
    {:noreply, announce(%{state | task: nil, status: status})}
  end

  # The check crashed: keep the old results, try again next tick.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{task: %Task{ref: ref}} = state) do
    {:noreply, announce(%{state | task: nil, status: %{state.status | checking: false}})}
  end

  def handle_info(_other, state), do: {:noreply, state}

  ## Checks

  defp start_check(%{task: %Task{}} = state), do: state

  defp start_check(state) do
    Process.send_after(self(), :tick, state.interval)
    servers = Turn.servers(state.servers.())

    if servers == %{} do
      status = %{state.status | configured: false, checking: false}
      announce(%{state | status: status})
    else
      opts = state.turn

      task =
        Task.Supervisor.async_nolink(Randos.TaskSupervisor, fn -> check_all(servers, opts) end)

      announce(%{state | task: task, status: %{state.status | configured: true, checking: true}})
    end
  end

  defp check_all(servers, opts),
    do:
      Map.new(servers, fn {transport, server} -> {transport, result(Turn.check(server, opts))} end)

  defp result(:ok), do: %{ok: true, reason: nil}
  defp result({:error, reason}), do: %{ok: false, reason: reason}

  defp stale?(%{task: %Task{}}), do: false
  defp stale?(%{status: %{checked_at: nil}}), do: true

  defp stale?(%{status: %{checked_at: at}, interval: interval}),
    do: DateTime.diff(DateTime.utc_now(), at, :millisecond) >= interval

  defp announce(state) do
    Phoenix.PubSub.broadcast(state.pubsub, @topic, {:relay_health, state.status})
    state
  end

  # Only the outcome: no address, credential or secret is ever logged.
  defp log(results) do
    Enum.each(results, fn
      {transport, %{ok: true}} ->
        Logger.debug("relay check ok (#{transport})")

      {transport, %{reason: reason}} ->
        Logger.warning("relay check failed (#{transport}): #{reason}")
    end)
  end
end
