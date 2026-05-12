defmodule Dsxir.Retrieval.InMemory do
  @moduledoc """
  Cosine-similarity brute-force retriever backed by a struct value.

      embedder = %Dsxir.Retrieval.Embedder{}
      index    = %Dsxir.Retrieval.InMemory{embedder: embedder}

      {:ok, index} = Dsxir.Retrieval.InMemory.add(index, ["alpha doc", "beta doc"])
      {:ok, hits}  = Dsxir.Retrieval.InMemory.search(index, "alpha-ish query", k: 1)

  No process, no ETS table. Mutation returns a new struct.

  ## Persistence

      :ok          = Dsxir.Retrieval.InMemory.save(index, "/tmp/idx.bin")
      {:ok, index} = Dsxir.Retrieval.InMemory.load("/tmp/idx.bin")

  Format is `:erlang.term_to_binary/1`; loads run with `[:safe]`.
  """

  alias Dsxir.Retrieval.Embedder

  @enforce_keys [:embedder]
  defstruct embedder: nil, docs: [], vectors: []

  @type t :: %__MODULE__{
          embedder: Embedder.t(),
          docs: [String.t()],
          vectors: [[float()]]
        }

  @spec add(t(), [String.t()], keyword()) :: {:ok, t()} | {:error, term()}
  def add(%__MODULE__{embedder: emb, docs: docs, vectors: vectors} = idx, new_docs, opts \\ [])
      when is_list(new_docs) do
    case Embedder.embed(emb, new_docs, opts) do
      {:ok, new_vectors, _usage} ->
        {:ok, %{idx | docs: docs ++ new_docs, vectors: vectors ++ new_vectors}}

      {:error, _} = err ->
        err
    end
  end

  @spec search(t(), String.t(), keyword()) ::
          {:ok, [%{doc: String.t(), score: float()}]} | {:error, term()}
  def search(%__MODULE__{embedder: emb, docs: docs, vectors: vectors}, query, opts \\ [])
      when is_binary(query) do
    k = Keyword.get(opts, :k, 3)

    case Embedder.embed(emb, [query], opts) do
      {:ok, [qv], _usage} ->
        ranked =
          docs
          |> Enum.zip(vectors)
          |> Enum.map(fn {doc, v} -> %{doc: doc, score: cosine(qv, v)} end)
          |> Enum.sort_by(& &1.score, :desc)
          |> Enum.take(k)

        {:ok, ranked}

      {:error, _} = err ->
        err
    end
  end

  @spec save(t(), Path.t()) :: :ok | {:error, File.posix()}
  def save(%__MODULE__{} = idx, path) do
    File.write(path, :erlang.term_to_binary(idx))
  end

  @spec load(Path.t()) :: {:ok, t()} | {:error, term()}
  def load(path) do
    with {:ok, bin} <- File.read(path) do
      {:ok, :erlang.binary_to_term(bin, [:safe])}
    end
  end

  defp cosine(a, b) when length(a) == length(b) do
    {dot, norm_a, norm_b} =
      a
      |> Enum.zip(b)
      |> Enum.reduce({0.0, 0.0, 0.0}, fn {x, y}, {d, na, nb} ->
        {d + x * y, na + x * x, nb + y * y}
      end)

    denom = :math.sqrt(norm_a) * :math.sqrt(norm_b)

    if denom == 0.0, do: 0.0, else: dot / denom
  end

  defp cosine(a, b) do
    raise %Dsxir.Errors.Framework.PredictorError{
      predictor: __MODULE__,
      signature: nil,
      inner: nil,
      reason: :vector_length_mismatch,
      trajectory: %{lengths: {length(a), length(b)}}
    }
  end
end
