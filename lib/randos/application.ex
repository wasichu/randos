defmodule Randos.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    :ok = RandosWeb.IceServers.check!()
    :ok = RandosWeb.VoiceProcessor.check!()
    # Every call's policy, on the call itself: what clients are told and what
    # the coordinator enforces are the same value.
    call_options =
      Application.get_env(:randos, :call_options, [])
      |> Keyword.put_new(:ice_transport_policy, RandosWeb.IceServers.transport_policy())

    children = [
      RandosWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:randos, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Randos.PubSub},
      {Task.Supervisor, name: Randos.TaskSupervisor},
      # The public status page: aggregate call counts and the relay's health.
      {Randos.Stats, store: stats_store()},
      RandosWeb.RelayHealth,
      {DynamicSupervisor, strategy: :one_for_one, name: Randos.Calls.CallSupervisor},
      {Randos.Matchmaking.Matchmaker, call_options: call_options},
      # Start to serve requests, typically the last entry
      RandosWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Randos.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Daily counters survive restarts only where there's somewhere to keep
  # them (RANDOS_STATS_DIR: a Fly volume in production).
  defp stats_store,
    do: if(Application.get_env(:randos, :stats_dir), do: Randos.Stats.FileStore)

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    RandosWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
