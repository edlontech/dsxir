defmodule Dsxir.Retrieval.InMemoryTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Dsxir.Retrieval.Embedder
  alias Dsxir.Retrieval.InMemory

  setup :set_mimic_from_context
  setup :verify_on_exit!

  @moduletag :tmp_dir

  defp config, do: {Dsxir.LM.Sycophant, [model: "fake:m", embedding_model: "fake:e"]}

  defp deterministic_embedder do
    expect(Sycophant, :embed, fn %Sycophant.EmbeddingRequest{inputs: inputs}, _opts ->
      vectors =
        Enum.map(inputs, fn input ->
          first = String.first(input) || "z"
          base = :erlang.phash2(first, 100) / 100.0
          [base, 1.0 - base, 0.5]
        end)

      {:ok,
       %Sycophant.EmbeddingResponse{
         embeddings: %{float: vectors},
         usage: %Sycophant.Usage{input_tokens: length(inputs), output_tokens: 0, total_cost: 0.0}
       }}
    end)
  end

  test "search/3 returns top-k by cosine descending" do
    deterministic_embedder()
    deterministic_embedder()

    Dsxir.Settings.context([lm: config()], fn ->
      {:ok, idx} =
        InMemory.add(%InMemory{embedder: %Embedder{}}, [
          "alpha-1",
          "alpha-2",
          "beta-1",
          "gamma-1"
        ])

      {:ok, [top | _]} = InMemory.search(idx, "alpha-query", k: 3)
      assert top.doc in ["alpha-1", "alpha-2"]
    end)
  end

  test "save/2 + load/1 roundtrips the index", %{tmp_dir: tmp} do
    deterministic_embedder()

    Dsxir.Settings.context([lm: config()], fn ->
      {:ok, idx} = InMemory.add(%InMemory{embedder: %Embedder{}}, ["a-1", "b-1", "c-1"])
      path = Path.join(tmp, "idx.bin")
      :ok = InMemory.save(idx, path)
      assert {:ok, %InMemory{docs: docs, vectors: vectors}} = InMemory.load(path)
      assert docs == idx.docs
      assert vectors == idx.vectors
    end)
  end

  test "search/3 short-circuits on embedder error" do
    expect(Sycophant, :embed, 1, fn _req, _opts ->
      {:error, %Sycophant.Error.Provider.RateLimited{retry_after: 10}}
    end)

    Dsxir.Settings.context([lm: config()], fn ->
      idx = %InMemory{embedder: %Embedder{}, docs: ["a"], vectors: [[0.1, 0.2, 0.3]]}
      assert {:error, %Dsxir.Errors.LM.RateLimited{}} = InMemory.search(idx, "any query")
    end)
  end
end
