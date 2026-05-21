defmodule Randos.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      RandosWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:randos, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Randos.PubSub},
      {DynamicSupervisor, strategy: :one_for_one, name: Randos.Calls.CallSupervisor},
      Randos.Matchmaking.Matchmaker,
      # Start a worker by calling: Randos.Worker.start_link(arg)
      # {Randos.Worker, arg},
      # Start to serve requests, typically the last entry
      RandosWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Randos.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    RandosWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
