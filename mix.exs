defmodule Dsxir.MixProject do
  use Mix.Project

  def project do
    [
      app: :dsxir,
      version: "0.1.0",
      elixir: "~> 1.19",
      description: description(),
      package: package(),
      start_permanent: Mix.env() == :prod,
      test_coverage: [tool: ExCoveralls],
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      dialyzer: dialyzer(),
      aliases: aliases(),
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Dsxir.Application, []}
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.post": :test,
        "coveralls.github": :test,
        "coveralls.html": :test,
        "test.integration": :test
      ]
    ]
  end

  defp aliases do
    [
      "test.integration": ["test --only integration"]
    ]
  end

  defp docs do
    [
      main: "Dsxir",
      extras: [
        "README.md",
        "guides/runtime_programs.md",
        "guides/tutorials/email_extraction.livemd",
        "guides/tutorials/knn_few_shot.livemd",
        "guides/tutorials/miprov2.livemd"
      ],
      groups_for_extras: [
        Guides: ~r"guides/[^/]+\.md",
        Tutorials: ~r"guides/tutorials/.?"
      ],
      groups_for_modules: [
        Core: [Dsxir, Dsxir.Program, Dsxir.Settings, Dsxir.CallContext],
        Signature: [
          Dsxir.Signature,
          Dsxir.Signature.Runtime,
          Dsxir.Signature.Compiled,
          Dsxir.Signature.Field
        ],
        Module: [
          Dsxir.Module,
          Dsxir.Module.Runtime,
          Dsxir.Module.PredictorDecl
        ],
        Adapter: [
          Dsxir.Adapter,
          Dsxir.Adapter.Chat,
          Dsxir.Adapter.Json
        ],
        Predictor: [
          Dsxir.Predictor,
          Dsxir.Predictor.Predict,
          Dsxir.Predictor.ChainOfThought,
          Dsxir.Predictor.ReAct,
          Dsxir.Predictor.Parallel
        ],
        Optimizer: [
          Dsxir.Optimizer,
          Dsxir.Optimizer.Cache,
          Dsxir.Optimizer.LabeledFewShot,
          Dsxir.Optimizer.BootstrapFewShot,
          Dsxir.Optimizer.BootstrapFewShot.Sampler,
          Dsxir.Optimizer.KNNFewShot,
          Dsxir.Optimizer.MIPROv2,
          Dsxir.Optimizer.MIPROv2.Sampler,
          Dsxir.Optimizer.MIPROv2.Stats,
          Dsxir.Optimizer.Search.Sampler,
          Dsxir.Optimizer.Search.Random,
          Dsxir.Optimizer.Search.TPE,
          Dsxir.OptimizerSession,
          Dsxir.OptimizerSession.Checkpoint,
          Dsxir.OptimizerSession.Store,
          Dsxir.OptimizerSession.Store.ETS,
          Dsxir.OptimizerSession.Store.File
        ],
        DemoStrategy: [
          Dsxir.DemoStrategy,
          Dsxir.DemoStrategy.KNN,
          Dsxir.DemoStrategy.KNN.Entry,
          Dsxir.DemoStrategy.KNN.EmbedText
        ],
        Evaluate: [Dsxir.Evaluate, Dsxir.EvaluationResult, Dsxir.Metric],
        Trace: [Dsxir.Trace],
        Retrieval: [
          Dsxir.Retrieval,
          Dsxir.Retrieval.Embedder,
          Dsxir.Retrieval.InMemory,
          Dsxir.Retrieval.Cosine
        ],
        Primitives: [
          Dsxir.Example,
          Dsxir.Prediction,
          Dsxir.Demo,
          Dsxir.Primitives.Tool,
          Dsxir.Primitives.History
        ],
        LM: [Dsxir.LM, Dsxir.LM.Sycophant],
        Telemetry: [Dsxir.Telemetry, Dsxir.History],
        Errors: [
          Dsxir.Errors,
          Dsxir.Errors.Halted,
          Dsxir.Errors.Halted.Plug,
          Dsxir.Errors.Invalid,
          Dsxir.Errors.Adapter,
          Dsxir.Errors.LM,
          Dsxir.Errors.Framework,
          Dsxir.Errors.Unknown
        ],
        Artifact: [Dsxir.Artifact]
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp dialyzer do
    [
      plt_add_apps: [:mix],
      ignore_warnings: ".dialyzer_ignore.exs"
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
      {:jason, "~> 1.4"},
      {:mimic, "~> 2.0", only: :test},
      {:mix_audit, ">= 0.0.0", only: [:dev, :test], runtime: false},
      {:nimble_parsec, "~> 1.4"},
      {:quiver, "~> 0.2"},
      {:stream_data, "~> 1.1", only: :test},
      {:recode, "~> 0.8", only: [:dev], runtime: false},
      {:spark, "~> 2.7"},
      {:sycophant, "~> 0.4", optional: true},
      {:tidewave, "~> 0.5", only: :dev, runtime: false}
    ]
  end

  defp description() do
    "An extensible framework for building and optimizing LLM-powered applications in Elixir."
  end

  defp package() do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/edlontech/dsxir"},
      files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE .formatter.exs)
    ]
  end
end
