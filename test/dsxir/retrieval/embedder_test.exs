defmodule Dsxir.Retrieval.EmbedderTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Dsxir.Retrieval.Embedder

  setup :set_mimic_from_context
  setup :verify_on_exit!

  defp config, do: {Dsxir.LM.Sycophant, [model: "fake:m", embedding_model: "fake:e"]}

  test "embed/2 issues exactly one LM call for 100 inputs at the default batch size" do
    inputs = for i <- 1..100, do: "doc_#{i}"
    vectors = for _ <- 1..100, do: [1.0, 0.0, 0.0]

    expect(Sycophant, :embed, 1, fn %Sycophant.EmbeddingRequest{inputs: got_inputs}, _opts ->
      assert length(got_inputs) == 100

      {:ok,
       %Sycophant.EmbeddingResponse{
         embeddings: %{float: vectors},
         usage: %Sycophant.Usage{input_tokens: 100, output_tokens: 0, total_cost: 0.0}
       }}
    end)

    Dsxir.Settings.context([lm: config()], fn ->
      assert {:ok, ^vectors, %Dsxir.Cost{input_tokens: 100}} = Embedder.embed(%Embedder{}, inputs)
    end)
  end

  test "embed/2 chunks at the configured batch size and concatenates in order" do
    inputs = for i <- 1..5, do: "doc_#{i}"

    expect(Sycophant, :embed, 3, fn %Sycophant.EmbeddingRequest{inputs: got}, _opts ->
      base = Enum.map(got, fn input -> [String.length(input) / 1.0] end)

      {:ok,
       %Sycophant.EmbeddingResponse{
         embeddings: %{float: base},
         usage: %Sycophant.Usage{input_tokens: length(got), output_tokens: 0, total_cost: 0.0}
       }}
    end)

    Dsxir.Settings.context([lm: config()], fn ->
      assert {:ok, vectors, %Dsxir.Cost{input_tokens: 5}} =
               Embedder.embed(%Embedder{batch_size: 2}, inputs)

      assert length(vectors) == 5
    end)
  end

  test "embed/2 short-circuits on the first batch error" do
    expect(Sycophant, :embed, 1, fn _req, _opts ->
      {:error, %Sycophant.Error.Provider.RateLimited{retry_after: 10}}
    end)

    Dsxir.Settings.context([lm: config()], fn ->
      assert {:error, %Dsxir.Errors.LM.RateLimited{}} =
               Embedder.embed(%Embedder{}, ["a", "b"])
    end)
  end
end
