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

  @doc """
  Embed `inputs` in chunks of `batch_size`. Returns the concatenated vectors
  and merged usage on success, or short-circuits on the first batch error.
  """
  @spec embed(t(), [String.t()], keyword()) ::
          {:ok, [[float()]], Dsxir.LM.usage()} | {:error, term()}
  def embed(%__MODULE__{batch_size: size}, inputs, opts \\ [])
      when is_list(inputs) and is_list(opts) and is_integer(size) and size > 0 do
    inputs
    |> Enum.chunk_every(size)
    |> Enum.reduce_while({:ok, [], Dsxir.LM.empty_usage()}, fn batch, {:ok, acc, usage_acc} ->
      case Dsxir.LM.embed(batch, opts) do
        {:ok, vectors, usage} ->
          {:cont, {:ok, acc ++ vectors, Dsxir.Cost.merge(usage_acc, usage)}}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
  end
end
