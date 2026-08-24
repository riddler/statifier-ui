defmodule StatifierUI.MixProject do
  use Mix.Project

  @version "0.1.0"
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
      docs: docs(),
      package: package(),
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

  # Hexdocs configuration. These paths are read off the publisher's disk at
  # `mix docs` time and need no entry in package()'s files: list - the docs
  # tarball hexdocs hosts is built separately from the package tarball
  # `mix deps.get` fetches.
  defp docs do
    [
      name: "StatifierUI",
      source_ref: "v#{@version}",
      canonical: "https://hexdocs.pm/statifier_ui",
      source_url: @source_url,
      main: "readme",
      extras: [
        "README.md",
        "CHANGELOG.md",
        "docs/architecture.md",
        "docs/wire-format.md"
      ],
      groups_for_extras: [
        Guides: ~r{docs/}
      ],
      skip_undefined_reference_warnings_on: ["CHANGELOG.md"]
    ]
  end

  defp package do
    [
      name: "statifier_ui",
      licenses: ["MIT"],
      files: ~w(lib mix.exs README.md LICENSE CHANGELOG.md),
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      }
    ]
  end

  defp deps do
    [
      statifier_dep(),

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
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:doctor, "~> 0.23", only: :dev, runtime: false}
    ]
  end

  # Export STATIFIER_PATH to point at a local checkout while co-developing a
  # change that spans both repos. It is an env var rather than a mix.exs edit
  # so the override never lands in a commit by accident.
  defp statifier_dep do
    case System.get_env("STATIFIER_PATH") do
      nil -> {:statifier, "~> 2.0"}
      path -> {:statifier, path: path, override: true}
    end
  end
end
