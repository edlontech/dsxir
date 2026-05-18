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

  @doc "Embed and append `new_docs` to the index, returning the updated struct."
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

  @doc """
  Return the top `:k` (default 3) documents ranked by cosine similarity against
  the embedded `query`.
  """
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

  @doc "Persist the index to `path` using `:erlang.term_to_binary/1`."
  @spec save(t(), Path.t()) :: :ok | {:error, File.posix()}
  def save(%__MODULE__{} = idx, path) do
    File.write(path, :erlang.term_to_binary(idx))
  end

  @doc "Load an index from `path` previously written by `save/2`."
  @spec load(Path.t()) :: {:ok, t()} | {:error, term()}
  def load(path) do
    with {:ok, bin} <- File.read(path) do
      {:ok, :erlang.binary_to_term(bin, [:safe])}
    end
  end

  defp cosine(a, b), do: Dsxir.Retrieval.Cosine.similarity(a, b)

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%Dsxir.Retrieval.InMemory{} = idx, opts) do
      concat([
        "#Dsxir.Retrieval.InMemory<",
        Integer.to_string(length(idx.docs)),
        " doc(s), embedder: ",
        to_doc(idx.embedder, opts),
        ">"
      ])
    end
  end
end
