defmodule Dsxir.Optimizer.KNNFewShotTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Dsxir.DemoStrategy.KNN
  alias Dsxir.Optimizer.KNNFewShot
  alias Dsxir.Program

  setup :set_mimic_from_context
  setup :verify_on_exit!

  defmodule QASig do
    use Dsxir.Signature

    signature do
      instruction("Answer.")
      input(:question, :string)
      output(:answer, :string)
    end
  end

  defmodule QAProg do
    use Dsxir.Module

    predictor(:qa, Dsxir.Predictor.Predict, signature: Dsxir.Optimizer.KNNFewShotTest.QASig)

    def forward(prog, %{question: q}), do: call(prog, :qa, %{question: q})
  end

  defp trainset_3 do
    [
      %Dsxir.Example{data: %{question: "what is x?", answer: "x is x"}},
      %Dsxir.Example{data: %{question: "what is y?", answer: "y is y"}},
      %Dsxir.Example{data: %{question: "what is z?", answer: "z is z"}}
    ]
  end

  defp stub_embed(vectors) do
    expect(Dsxir.LM.Sycophant, :embed, fn _cfg, texts, _opts ->
      taken = Enum.take(vectors, length(texts))
      {:ok, taken, %{tokens_in: length(texts), tokens_out: nil, cost: nil}}
    end)
  end

  test "empty trainset returns Invalid.Trainset error" do
    prog = Program.new(QAProg)

    result =
      Dsxir.Settings.context([lm: {Dsxir.LM.Sycophant, [model: "x"]}], fn ->
        KNNFewShot.compile(prog, [], nil, [])
      end)

    assert {:error, %Dsxir.Errors.Invalid.Trainset{reason: :empty}} = result
  end

  test "k < 1 returns Invalid.Configuration" do
    prog = Program.new(QAProg)

    {:error, err} =
      Dsxir.Settings.context([lm: {Dsxir.LM.Sycophant, [model: "x"]}], fn ->
        KNNFewShot.compile(prog, trainset_3(), nil, k: 0)
      end)

    assert %Dsxir.Errors.Invalid.Configuration{key: :k, reason: :must_be_positive} = err
  end

  test "embed_fields with unknown field returns Invalid.Configuration" do
    prog = Program.new(QAProg)

    {:error, err} =
      Dsxir.Settings.context([lm: {Dsxir.LM.Sycophant, [model: "x"]}], fn ->
        KNNFewShot.compile(prog, trainset_3(), nil, embed_fields: [:not_a_field])
      end)

    assert %Dsxir.Errors.Invalid.Configuration{key: :embed_fields, reason: :unknown_field} = err
  end

  test "successful compile slots strategy on every predictor, zeroes demos, stamps metadata" do
    stub_embed([[1.0, 0.0], [0.0, 1.0], [0.5, 0.5]])

    prog = Program.new(QAProg)

    {:ok, compiled, stats} =
      Dsxir.Settings.context([lm: {Dsxir.LM.Sycophant, [model: "embed-m"]}], fn ->
        KNNFewShot.compile(prog, trainset_3(), nil, k: 2)
      end)

    state = Program.get_state(compiled, :qa)
    assert state.demos == []
    assert %KNN{k: 2, embedder_id: "embed-m", entries: entries} = state.demo_strategy
    assert length(entries) == 3

    assert compiled.metadata.compiled_with == KNNFewShot
    assert compiled.metadata.trainset_hash != nil
    assert compiled.metadata.score == nil

    assert stats.k == 2
    assert stats.embedder_id == "embed-m"
    assert stats.entries_per_predictor[:qa] == 3
    assert stats.embedding_tokens == 3
    assert is_integer(stats.compile_duration_ms)
  end

  test "embedder failure bubbles out of compile/4 as the underlying error" do
    expect(Dsxir.LM.Sycophant, :embed, fn _cfg, _texts, _opts ->
      {:error, :nope}
    end)

    prog = Program.new(QAProg)

    result =
      Dsxir.Settings.context([lm: {Dsxir.LM.Sycophant, [model: "x"]}], fn ->
        KNNFewShot.compile(prog, trainset_3(), nil, [])
      end)

    assert {:error, :nope} = result
  end

  test "embedder config without :model returns Invalid.Configuration before embedding" do
    reject(&Dsxir.LM.Sycophant.embed/3)

    prog = Program.new(QAProg)

    result =
      Dsxir.Settings.context([lm: {Dsxir.LM.Sycophant, [model: "gen-model"]}], fn ->
        KNNFewShot.compile(prog, trainset_3(), nil, embedder: {Dsxir.LM.Sycophant, []})
      end)

    assert {:error, %Dsxir.Errors.Invalid.Configuration{key: :embedder, reason: :missing_model}} =
             result
  end

  test "explicit :embedder opt overrides the active :lm and strips credentials" do
    expect(Dsxir.LM.Sycophant, :embed, fn cfg, _texts, _opts ->
      assert Keyword.get(cfg, :model) == "explicit-embed"
      {:ok, [[1.0], [0.0], [0.5]], Dsxir.LM.empty_usage()}
    end)

    prog = Program.new(QAProg)

    {:ok, compiled, _stats} =
      Dsxir.Settings.context(
        [lm: {Dsxir.LM.Sycophant, [model: "gen-model", api_key: "x"]}],
        fn ->
          KNNFewShot.compile(
            prog,
            trainset_3(),
            nil,
            embedder: {Dsxir.LM.Sycophant, [model: "explicit-embed", api_key: "embed-k"]}
          )
        end
      )

    state = Program.get_state(compiled, :qa)
    assert {Dsxir.LM.Sycophant, stored_config} = state.demo_strategy.embedder
    refute Keyword.has_key?(stored_config, :api_key)
    assert Keyword.get(stored_config, :model) == "explicit-embed"
  end

  test "compile/4 over a runtime-program source enumerates predictors via Source.predictors/1" do
    expect(Dsxir.LM.Sycophant, :embed, fn _cfg, _texts, _opts ->
      {:ok, [[1.0, 0.0], [0.0, 1.0], [0.5, 0.5]], %{tokens_in: 3, tokens_out: nil, cost: nil}}
    end)

    rp = Dsxir.Test.Fixtures.RuntimePrograms.equivalent_to_qa()
    prog = Program.from_runtime(rp)

    trainset = [
      %Dsxir.Example{data: %{q: "what is x?", a: "x is x"}},
      %Dsxir.Example{data: %{q: "what is y?", a: "y is y"}},
      %Dsxir.Example{data: %{q: "what is z?", a: "z is z"}}
    ]

    {:ok, compiled, stats} =
      Dsxir.Settings.context([lm: {Dsxir.LM.Sycophant, [model: "embed-m"]}], fn ->
        KNNFewShot.compile(prog, trainset, nil, k: 2)
      end)

    assert stats.entries_per_predictor[:answer] == 3
    state = Program.get_state(compiled, :answer)
    assert %KNN{k: 2} = state.demo_strategy
  end
end
