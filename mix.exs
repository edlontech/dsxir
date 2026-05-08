defmodule Dsxir.MixProject do
  use Mix.Project

  def project do
    [
      app: :dsxir,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Dsxir.Application, []}
    ]
  end

  defp deps do
    [
      {:bandit, "~> 1.8", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:doctor, "~> 0.22", only: :dev},
      {:dune, "~> 0.3"},
      {:ex_check, "~> 0.16", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: [:dev, :test]},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:mix_audit, ">= 0.0.0", only: [:dev, :test], runtime: false},
      {:quiver, "~> 0.2"},
      {:recode, "~> 0.8", only: [:dev], runtime: false},
      {:spark, "~> 2.7"},
      {:sycophant, "~> 0.4"},
      {:tidewave, "~> 0.5", only: :dev, runtime: false},
    ]
  end
end
