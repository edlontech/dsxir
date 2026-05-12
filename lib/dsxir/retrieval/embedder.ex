defmodule Dsxir.Retrieval.Embedder do
  @moduledoc """
  Batched wrapper around `Dsxir.LM.embed/2`.

      embedder = %Dsxir.Retrieval.Embedder{batch_size: 256}
      {:ok, vectors, usage} = Dsxir.Retrieval.Embedder.embed(embedder, ["a", "b", ...])

  Inputs larger than `:batch_size` are chunked; results are concatenated in
  input order. Errors short-circuit and surface the first failure.
  """

  defstruct batch_size: 256

  @type t :: %__MODULE__{batch_size: pos_integer()}

  @spec embed(t(), [String.t()], keyword()) ::
          {:ok, [[float()]], Dsxir.LM.usage()} | {:error, term()}
  def embed(%__MODULE__{batch_size: size}, inputs, opts \\ [])
      when is_list(inputs) and is_list(opts) and is_integer(size) and size > 0 do
    inputs
    |> Enum.chunk_every(size)
    |> Enum.reduce_while({:ok, [], Dsxir.LM.empty_usage()}, fn batch, {:ok, acc, usage_acc} ->
      case Dsxir.LM.embed(batch, opts) do
        {:ok, vectors, usage} ->
          {:cont, {:ok, acc ++ vectors, merge_usage(usage_acc, usage)}}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
  end

  defp merge_usage(a, b) do
    %{
      tokens_in: add_nil(a.tokens_in, b.tokens_in),
      tokens_out: add_nil(a.tokens_out, b.tokens_out),
      cost: add_nil(a.cost, b.cost)
    }
  end

  defp add_nil(nil, nil), do: nil
  defp add_nil(nil, b), do: b
  defp add_nil(a, nil), do: a
  defp add_nil(a, b), do: a + b
end
