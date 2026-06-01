defmodule Meerkat.MixProject do
  use Mix.Project

  def project do
    [
      app: :meerkat,
      version: "1.0.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      releases: releases()
    ]
  end

  defp releases do
    # `scripts/install.sh` runs `mix release` and wraps the output in
    # a launcher at ~/.local/bin/meerkat. Auto-install via the
    # lefthook post-merge hook uses this path.
    [
      meerkat: [
        steps: [:assemble],
        include_executables_for: [:unix]
      ]
    ]
  end

  def application do
    [
      mod: {Meerkat.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test, muex: :test]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix, "~> 1.8.5"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.1.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:stream_data, "~> 1.0", only: :test},
      {:live_svelte, "~> 0.18"},
      {:phoenix_vite, "~> 0.4"},
      # Comment-body rendering. earmark parses Markdown (GFM
      # tables/fences/lists); html_sanitize_ex strips `<script>` /
      # event handlers / javascript: URLs from the result so a
      # hostile comment body can't fire JS in the local review tab.
      {:earmark, "~> 1.4"},
      {:html_sanitize_ex, "~> 1.4"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      # Mutation testing — `mix muex` rewrites operators / literals
      # in `lib/` and runs the test suite against each rewrite. A
      # mutation that ALL tests pass against = a test gap. See
      # `scripts/mutate.sh` for the entry point.
      {:muex, "~> 0.6", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "assets.setup", "assets.build"],
      "assets.setup": ["phoenix_vite.npm assets install"],
      "assets.build": ["phoenix_vite.npm assets exec -- vite build"],
      "assets.deploy": ["phoenix_vite.npm assets exec -- vite build", "phx.digest"],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end
end
