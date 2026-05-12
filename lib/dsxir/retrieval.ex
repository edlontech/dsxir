defmodule Dsxir.Retrieval do
  @moduledoc """
  Retrieval primitives.

    * `Dsxir.Retrieval.Embedder` — batched wrapper around `Dsxir.LM.embed/2`.
    * `Dsxir.Retrieval.InMemory` — cosine-similarity brute-force retriever
      backed by a struct value (no process, no ETS table).
  """
end
