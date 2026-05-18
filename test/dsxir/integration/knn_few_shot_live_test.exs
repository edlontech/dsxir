defmodule Dsxir.Integration.KnnFewShotLiveTest do
  use ExUnit.Case, async: false

  alias Dsxir.Optimizer.KNNFewShot
  alias Dsxir.Program

  @moduletag :integration
  @moduletag :live_lm

  defmodule QASig do
    use Dsxir.Signature

    signature do
      instruction("Answer the question concisely.")
      input(:question, :string)
      output(:answer, :string)
    end
  end

  defmodule QAProg do
    use Dsxir.Module

    predictor(:qa, Dsxir.Predictor.Predict, signature: Dsxir.Integration.KnnFewShotLiveTest.QASig)

    def forward(prog, %{question: q}), do: call(prog, :qa, %{question: q})
  end

  setup do
    case System.get_env("OPENAI_API_KEY") do
      key when is_binary(key) and key != "" -> {:ok, api_key: key}
      _ -> {:skip, "OPENAI_API_KEY not set"}
    end
  end

  test "compile, save, load, forward with real OpenAI embeddings", %{api_key: key} do
    trainset =
      Enum.map(
        [
          {"what is the capital of france?", "paris"},
          {"what is the capital of germany?", "berlin"},
          {"what is the capital of spain?", "madrid"},
          {"what is the largest planet?", "jupiter"},
          {"what is the smallest planet?", "mercury"}
        ],
        fn {q, a} -> %Dsxir.Example{data: %{question: q, answer: a}} end
      )

    Dsxir.Settings.context(
      [
        lm: {Dsxir.LM.Sycophant, [model: "openai:gpt-4o-mini", api_key: key]},
        adapter: Dsxir.Adapter.Chat
      ],
      fn ->
        prog = Program.new(QAProg)

        {:ok, compiled, stats} =
          KNNFewShot.compile(prog, trainset, nil,
            k: 2,
            embedder: {Dsxir.LM.Sycophant, [model: "openai:text-embedding-3-small", api_key: key]}
          )

        assert stats.entries_per_predictor[:qa] == 5
        assert stats.embedding_tokens > 0

        tmp = Path.join(System.tmp_dir!(), "knn-live-#{System.unique_integer([:positive])}.json")
        {:ok, ^tmp} = Dsxir.Artifact.save(compiled, tmp)
        {:ok, loaded} = Dsxir.Artifact.load(QAProg, tmp)
        File.rm!(tmp)

        {_prog, prediction} = QAProg.forward(loaded, %{question: "what is the capital of italy?"})
        answer = prediction.fields[:answer]
        assert is_binary(answer)
        assert String.length(answer) > 0
      end
    )
  end
end
