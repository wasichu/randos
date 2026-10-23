defmodule Tui.MixProject do
  use Mix.Project

  def project do
    [
      app: :tui,
      version: "0.6.2",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      releases: releases(),
      # As the server's: no line numbers in the template, and no guessed
      # (fuzzy) translations for a reworded string.
      gettext: [write_reference_line_numbers: false, fuzzy_threshold: 1.0]
    ]
  end

  # `MIX_ENV=prod mix release randos_tui` (or `just tui-release`): a
  # self-contained directory (ERTS included) with `bin/randos`, the command
  # people run, and the media helper bundled in the app's priv/. Named
  # randos_tui because a release named randos would own bin/randos itself.
  defp releases do
    [
      randos_tui: [
        include_executables_for: [:unix],
        steps: [:assemble, &bundle_helper/1]
      ]
    ]
  end

  # The helper's release build (`cargo build --release -p randos_media` at
  # the repo root), or RANDOS_MEDIA_BIN, copied in next to the app.
  defp bundle_helper(release) do
    source =
      System.get_env("RANDOS_MEDIA_BIN") ||
        Path.expand("../../target/release/randos_media", __DIR__)

    unless File.exists?(source) do
      Mix.raise("no media helper at #{source}: cargo build --release -p randos_media first")
    end

    priv = Path.join([release.path, "lib", "tui-#{release.version}", "priv"])
    File.mkdir_p!(priv)
    File.cp!(source, Path.join(priv, "randos_media"))
    File.chmod!(Path.join(priv, "randos_media"), 0o755)
    release
  end

  # Test helpers shared across the test files (Tui.TestSupport).
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

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
      # The interface's translations, as the server does them.
      {:gettext, "~> 1.0"},
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
        # The translation template must match the code (mix gettext.extract).
        "gettext.extract --check-up-to-date",
        "test"
      ]
    ]
  end
end
