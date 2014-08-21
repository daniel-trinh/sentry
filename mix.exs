defmodule Sentry.Mixfile do
  use Mix.Project

  def project do
    [app: :sentry,
     version: "0.0.1",
     elixir: "~> 0.15.1",
     deps: deps]
  end

  # Configuration for the OTP application
  #
  # Type `mix help compile.app` for more information
  def application do
    [applications: [:logger]]
  end

  # Dependencies can be Hex packages:
  #
  #   {:mydep, "~> 0.3.0"}
  #
  # Or git/path repositories:
  #
  #   {:mydep, git: "https://github.com/elixir-lang/mydep.git", tag: "0.1.0"}
  #
  # Type `mix help deps` for more examples and options
  defp deps do
    [
      {:sync, git: "git@github.com:daniel-trinh/sync.git"},
      {:streamz, git: "git@github.com:hamiltop/streamz.git"}
    ]
  end
end