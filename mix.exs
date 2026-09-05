defmodule ScenicWidgets.MixProject do
  use Mix.Project

  def project do
    [
      app: :scenic_widget_contrib,
      version: "0.1.0",
      elixir: "~> 1.12",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      preferred_cli_env: [
        spex: :test
      ]
    ]
  end

  # Fast pre-commit gate, run by .githooks/pre-commit (activate with
  # `git config core.hooksPath .githooks`). Kept minimal on purpose: the wider suite
  # can't gate yet — lib/ isn't fully formatted, a spex file has non-Elixir syntax, and
  # EnhancedMenuBarTest is currently broken. Add `format --check-formatted` and a scoped
  # `test` step once that debt is cleared.
  defp aliases do
    [
      precommit: [
        "compile",
        "deps.unlock --check-unused"
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {ScenicWidgets.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:scenic, git: "https://github.com/JediLuke/scenic.git", branch: "main", override: true},
      {:scenic_driver_local, git: "https://github.com/JediLuke/scenic_driver_local.git", branch: "main", override: true},
      {:font_metrics, "~> 0.5"},
      {:ex_doc, "~> 0.25", only: :dev},
      {:earmark, "~> 1.4", only: :dev},
      # {:stream_data, "~> 1.0", only: :test},
      # Added dependencies for widget development
      {:scenic_mcp, git: "https://github.com/scenic-contrib/scenic_mcp_experimental.git", branch: "main", optional: true},
      {:sexy_spex, git: "https://github.com/JediLuke/spex.git", branch: "main", optional: true},
      {:scenic_live_reload, git: "https://github.com/axelson/scenic_live_reload.git", branch: "main", only: :dev},
      {:tidewave, "~> 0.1", only: :dev},
      {:bandit, "~> 1.0", only: :dev}
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/helpers"]
  defp elixirc_paths(_), do: ["lib"]
end
