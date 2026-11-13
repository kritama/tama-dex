defmodule Tama.Dex.MixProject do
  use Mix.Project

  @version "0.1.0-dev"
  @source_url "https://github.com/kritama/tama-dex"

  def project do
    [
      app: :tama_dex,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description: description(),
      source_url: @source_url,
      homepage_url: @source_url,
      package: package(),
      docs: docs(),
      dialyzer: dialyzer(),
      test_coverage: [ignore_modules: [~r/^Tama\.Dex\.TestSupport\./]],
      aliases: aliases()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  # A library application: no `mod:` callback, so loading or starting
  # `:tama_dex` starts no process, opens no database and creates no file.
  def application do
    [
      extra_applications: [:crypto, :logger]
    ]
  end

  def cli do
    [preferred_envs: [precommit: :test]]
  end

  defp description do
    "Index, search and validated execute for Tama operations profile documents."
  end

  defp package do
    [
      files:
        ~w(lib priv/profile docs/tama-operations-profile.md mix.exs README.md CHANGELOG.md LICENSE),
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: [
        "README.md",
        "docs/tama-operations-profile.md",
        "CHANGELOG.md",
        "LICENSE"
      ]
    ]
  end

  defp dialyzer do
    [
      plt_core_path: "priv/plts",
      plt_add_apps: [:ex_unit, :mix],
      plt_file: {:no_warn, "priv/plts/dialyzer.plt"}
    ]
  end

  defp deps do
    [
      {:exqlite, "~> 0.43"},
      {:jason, "~> 1.4"},
      {:jsonschex, "~> 0.11.2"},
      {:telemetry, "~> 1.3"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      precommit: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --strict",
        "test --cover"
      ]
    ]
  end
end
