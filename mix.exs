defmodule Randos.MixProject do
  use Mix.Project

  def project do
    [
      app: :randos,
      version: "0.1.0",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      usage_rules: usage_rules(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      consolidate_protocols: Mix.env() != :dev
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Randos.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  # Usage rules for LLMs: short Elixir/OTP rules are inlined into AGENTS.md;
  # framework rules become on-demand skills. Run `mix usage_rules.sync`.
  defp usage_rules do
    [
      file: "AGENTS.md",
      usage_rules: [{:usage_rules, sub_rules: ["elixir", "otp"]}],
      skills: [
        location: ".claude/skills",
        build: [
          "phoenix-framework": [
            description:
              "Use when working on the Randos web layer: Phoenix, HEEx templates, LiveView (streams, forms, hooks, tests). Consult before editing lib/randos_web.",
            usage_rules: [
              {:phoenix, sub_rules: ["phoenix", "elixir", "html", "liveview"]},
              ~r/^phoenix_/
            ]
          ],
          "ex-ratatui": [
            description:
              "Use when building terminal UIs with ex_ratatui (the dev monitor in dev/, and the TUI client in clients/tui): widgets, layout, App callbacks, testing.",
            usage_rules: [:ex_ratatui]
          ]
        ]
      ]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  # dev/ holds dev-only tools (the `just top` monitor); never compiled for prod.
  defp elixirc_paths(:test), do: ["lib", "dev", "test/support"]
  defp elixirc_paths(:dev), do: ["lib", "dev"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:sourceror, "~> 1.8", only: [:dev, :test]},
      {:usage_rules, "~> 1.0", only: [:dev]},
      {:tidewave, "~> 0.9", only: :dev},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      # Dev-only terminal dashboard (`just top`); never in the release.
      {:ex_ratatui, "~> 0.17", only: [:dev, :test]},
      {:phoenix, "~> 1.8"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2"},
      {:lazy_html, "~> 0.1", only: :test},
      {:phoenix_live_dashboard, "~> 0.9"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.3"},
      {:bandit, "~> 1.5"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "assets.setup", "assets.build"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind randos", "esbuild randos"],
      "assets.deploy": [
        "tailwind randos --minify",
        "esbuild randos --minify",
        "phx.digest"
      ],
      precommit: [
        "compile --warning-as-errors",
        "deps.unlock --unused",
        "format",
        "credo --strict",
        "test"
      ]
    ]
  end
end
