defmodule Dsxir.ArtifactKnnTest do
  use ExUnit.Case, async: true

  alias Dsxir.Artifact
  alias Dsxir.DemoStrategy.KNN
  alias Dsxir.DemoStrategy.KNN.Entry
  alias Dsxir.Errors.Invalid.Configuration
  alias Dsxir.Program

  defmodule Sig do
    @moduledoc "Answer the question."

    use Dsxir.Signature

    signature do
      input(:question, :string)
      output(:answer, :string)
    end
  end

  defmodule Prog do
    use Dsxir.Module

    predictor(:qa, Dsxir.Predictor.Predict, signature: Sig)

    def forward(p, inputs), do: call(p, :qa, inputs)
  end

  defp ex(q, a), do: Dsxir.Example.new(%{question: q, answer: a}, input_keys: [:question])

  defp entry(vec, q, a), do: %Entry{embedding: vec, example: ex(q, a)}

  defp strategy(opts) do
    %KNN{
      k: Keyword.get(opts, :k, 2),
      embedder: Keyword.get(opts, :embedder, {Dsxir.LM.Sycophant, [model: "test-embed"]}),
      embedder_id: Keyword.get(opts, :embedder_id, "test-embed"),
      embed_fields: Keyword.get(opts, :embed_fields, :all),
      entries:
        Keyword.get(opts, :entries, [
          entry([1.0, 0.0], "q1", "a1"),
          entry([0.0, 1.0], "q2", "a2")
        ])
    }
  end

  defp prog_with_strategy(strategy) do
    %Program{
      module: Prog,
      predictors: %{qa: %Program.State{demos: [], demo_strategy: strategy}}
    }
  end

  @tag :tmp_dir
  test "round-trip preserves KNN strategy structure", %{tmp_dir: tmp_dir} do
    strat = strategy([])
    path = Path.join(tmp_dir, "dsxir-knn-roundtrip.json")
    {:ok, ^path} = Artifact.save(prog_with_strategy(strat), path)

    {:ok, loaded} = Artifact.load(Prog, path)
    state = Program.get_state(loaded, :qa)

    assert %KNN{
             k: 2,
             embedder: {Dsxir.LM.Sycophant, embedder_config},
             embedder_id: "test-embed",
             embed_fields: :all,
             entries: entries
           } = state.demo_strategy

    assert Keyword.get(embedder_config, :model) == "test-embed"
    assert length(entries) == 2

    [first, second] = entries

    assert %Entry{
             embedding: [1.0, +0.0],
             example: %Dsxir.Example{data: %{question: "q1", answer: "a1"}}
           } = first

    assert %Entry{
             embedding: [+0.0, 1.0],
             example: %Dsxir.Example{data: %{question: "q2", answer: "a2"}}
           } = second
  end

  @tag :tmp_dir
  test "credentials are stripped from serialized JSON", %{tmp_dir: tmp_dir} do
    strat =
      strategy(
        embedder:
          {Dsxir.LM.Sycophant,
           [
             model: "test-embed",
             api_key: "SECRET",
             base_url: "https://example.test",
             headers: [{"x-token", "secret-value"}]
           ]}
      )

    path = Path.join(tmp_dir, "dsxir-knn-credstrip.json")
    {:ok, ^path} = Artifact.save(prog_with_strategy(strat), path)

    raw = File.read!(path)
    refute String.contains?(raw, "SECRET")
    refute String.contains?(raw, "api_key")
    refute String.contains?(raw, "base_url")
    refute String.contains?(raw, "headers")
    refute String.contains?(raw, "x-token")
    refute String.contains?(raw, "secret-value")
  end

  @tag :tmp_dir
  test "explicit embed_fields list round-trips as atoms", %{tmp_dir: tmp_dir} do
    strat = strategy(embed_fields: [:question])
    path = Path.join(tmp_dir, "dsxir-knn-embedfields.json")
    {:ok, ^path} = Artifact.save(prog_with_strategy(strat), path)

    raw = File.read!(path)
    decoded = Jason.decode!(raw)
    assert decoded["qa"]["demo_strategy"]["embed_fields"] == ["question"]

    {:ok, loaded} = Artifact.load(Prog, path)
    state = Program.get_state(loaded, :qa)
    assert state.demo_strategy.embed_fields == [:question]
  end

  @tag :tmp_dir
  test "artifact without demo_strategy key loads with demo_strategy: nil", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "dsxir-knn-legacy.json")

    legacy = %{
      "qa" => %{
        "instructions" => nil,
        "demos" => [%{"question" => "q1", "answer" => "a1", "_kind" => "labeled"}]
      },
      "_metadata" => %{
        "compiled_with" => nil,
        "score" => nil,
        "trainset_hash" => nil
      }
    }

    File.write!(path, Jason.encode!(legacy))

    {:ok, prog} = Artifact.load(Prog, path)
    state = Program.get_state(prog, :qa)
    assert state.demo_strategy == nil
    assert length(state.demos) == 1
  end

  @tag :tmp_dir
  test "unknown demo_strategy kind returns Invalid.Configuration error tuple",
       %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "dsxir-knn-unknown-kind.json")

    payload = %{
      "qa" => %{
        "instructions" => nil,
        "demos" => [],
        "demo_strategy" => %{
          "kind" => "mystery",
          "k" => 2
        }
      },
      "_metadata" => %{
        "compiled_with" => nil,
        "score" => nil,
        "trainset_hash" => nil
      }
    }

    File.write!(path, Jason.encode!(payload))

    assert {:error, %Configuration{key: :demo_strategy, reason: :unknown_kind, value: "mystery"}} =
             Artifact.load(Prog, path)
  end
end
