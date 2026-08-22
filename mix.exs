defmodule StatifierUI.MixProject do
  use Mix.Project

  @version "0.1.0-dev"
  @source_url "https://github.com/riddler/statifier-ui"

  def project do
    [
      app: :statifier_ui,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "StatifierUI",
      description: "UI components for authoring, observing, and debugging statifier statecharts",
      source_url: @source_url,
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.html": :test
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      # Statifier is not published to hex yet, so the engine is a git dep and
      # mix.lock pins the SHA. This becomes a version requirement the day
      # statifier publishes; nothing else here depends on which form it takes.
      {:statifier, github: "riddler/statifier-ex"},

      # Both integrations are optional: the package is a component library, and
      # a Livebook host has no reason to pull LiveView, or the reverse. Anything
      # under lib/ that touches one of these has to tolerate its absence at
      # compile time.
      {:kino, "~> 0.14", optional: true},
      {:phoenix_live_view, "~> 1.0", optional: true},

      # Dev / test
      {:ex_quality, "~> 0.14", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:doctor, "~> 0.23", only: :dev, runtime: false}
    ]
  end
end
