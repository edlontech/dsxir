defmodule Dsxir.Retrieval.Cosine do
  @moduledoc """
  Brute-force cosine similarity over two flat float lists.

  Pulled out of `Dsxir.Retrieval.InMemory` so the `Dsxir.DemoStrategy.KNN`
  strategy can share the same math without copy-pasting. Returns `0.0` when
  either vector is the zero vector, mirroring the original semantics.
  """

  alias Dsxir.Errors

  @doc """
  Cosine similarity in [-1.0, 1.0]. Returns `0.0` when either input is the
  zero vector. Raises `Dsxir.Errors.Framework.PredictorError` when vector
  lengths differ.
  """
  @spec similarity([float()], [float()]) :: float()
  def similarity(a, b) when is_list(a) and is_list(b) and length(a) == length(b) do
    {dot, norm_a, norm_b} =
      a
      |> Enum.zip(b)
      |> Enum.reduce({0.0, 0.0, 0.0}, fn {x, y}, {d, na, nb} ->
        {d + x * y, na + x * x, nb + y * y}
      end)

    denom = :math.sqrt(norm_a) * :math.sqrt(norm_b)
    if denom == 0.0, do: 0.0, else: dot / denom
  end

  def similarity(a, b) when is_list(a) and is_list(b) do
    raise %Errors.Framework.PredictorError{
      predictor: __MODULE__,
      signature: nil,
      inner: nil,
      reason: :vector_length_mismatch,
      trajectory: %{lengths: {length(a), length(b)}}
    }
  end
end
