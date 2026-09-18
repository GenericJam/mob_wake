defmodule MobWake.MixProject do
  use Mix.Project

  @source_url "https://github.com/GenericJam/mob_wake"
  @version "0.1.0"

  def project do
    [
      app: :mob_wake,
      version: @version,
      elixir: "~> 1.17",
      deps: deps(),
      aliases: aliases(),
      description:
        "OS-triggered background execution for Mob apps — iOS BGTaskScheduler + silent APNs, Android WorkManager + FCM data. Unified identifier → MFA dispatch across all four trigger sources.",
      package: package(),
      docs: [
        main: "readme",
        extras: ["README.md", "CHANGELOG.md"]
      ],
      source_url: @source_url
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp aliases do
    # `mix setup` after cloning: fetches deps and activates the shared git
    # hooks (.githooks): format / Credo --strict / compile on every push and
    # the full suite when mix.exs changes — the same gate CI enforces.
    [setup: ["deps.get", "cmd git config core.hooksPath .githooks"]]
  end

  defp deps do
    [
      {:mob, "~> 0.9.1"},
      {:mob_dev, "~> 0.6", only: [:dev, :test], runtime: false},
      # Code quality — Credo + ex_slop (AI-pattern checks) + jump_credo_checks,
      # mirroring mob core's pre-commit gate.
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4.2", only: [:dev, :test], runtime: false},
      {:jump_credo_checks, "~> 0.1.0", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      # Native sources + manifest must ship in the package — the host's
      # native build compiles them from deps/mob_wake/priv/.
      files: ~w(lib src priv mix.exs README* CHANGELOG* LICENSE*)
    ]
  end
end
