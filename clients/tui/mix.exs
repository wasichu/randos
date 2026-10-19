defmodule Tui.MixProject do
  use Mix.Project

  def project do
    [
      app: :tui,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  def cli do
    [preferred_envs: [precommit: :test]]
  end

  def application do
    [extra_applications: [:logger]]
  end

  # Kept small on purpose (see AGENTS.md: justify every dependency).
  defp deps do
    [
      # Terminal UI (ratatui via precompiled NIFs).
      {:ex_ratatui, "~> 0.17"},
      # Phoenix channels client: join, heartbeats, reconnect/rejoin, and a
      # SocketTest helper; the alternative is hand-writing that protocol.
      {:slipstream, "~> 1.2"},
      {:jason, "~> 1.4"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "credo --strict",
        "test"
      ]
    ]
  end
end
