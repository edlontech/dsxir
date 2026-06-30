defmodule Dsxir.Demo do
  @moduledoc """
  A demo slotted into a predictor by an optimizer.

  Wraps a `%Dsxir.Example{}` with a provenance tag. The chat adapter and the
  json adapter render `%Dsxir.Demo{}` and `%Dsxir.Example{}` identically; the
  tag is preserved across save/load via `Dsxir.Artifact`.

  `kind` values:

    * `:labeled` - slotted directly from the trainset, no LM call.
    * `:bootstrapped` - captured from a successful `Dsxir.with_trace/1` round
      run by an optimizer (e.g. `Dsxir.Optimizer.BootstrapFewShot`).

  `source` is populated only for `:bootstrapped` demos and carries a provenance
  map describing what produced the captured trace — e.g. the round and trainset
  example index for `Dsxir.Optimizer.BootstrapFewShot`, or the originating
  strategy for `Dsxir.Optimizer.SIMBA`.
  """

  @enforce_keys [:example, :kind]
  defstruct [:example, :kind, source: nil]

  @type kind :: :labeled | :bootstrapped

  @type source :: nil | map()

  @type t :: %__MODULE__{
          example: Dsxir.Example.t(),
          kind: kind(),
          source: source()
        }

  @doc "Wrap `ex` as a labeled demo (provenance: directly from the trainset)."
  @spec labeled(Dsxir.Example.t()) :: t()
  def labeled(%Dsxir.Example{} = ex), do: %__MODULE__{example: ex, kind: :labeled}

  @doc """
  Wrap `ex` as a bootstrapped demo captured from a successful trace round.
  `source` is a provenance map describing what produced it (e.g. round and
  trainset example index, or the originating optimizer strategy).
  """
  @spec bootstrapped(Dsxir.Example.t(), source()) :: t()
  def bootstrapped(%Dsxir.Example{} = ex, source) when is_map(source) do
    %__MODULE__{example: ex, kind: :bootstrapped, source: source}
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%Dsxir.Demo{example: ex, kind: kind, source: nil}, opts) do
      concat(["#Dsxir.Demo<", to_doc(kind, opts), ", ", to_doc(ex, opts), ">"])
    end

    def inspect(%Dsxir.Demo{example: ex, kind: kind, source: source}, opts) do
      concat([
        "#Dsxir.Demo<",
        to_doc(kind, opts),
        ", source: ",
        to_doc(source, opts),
        ", ",
        to_doc(ex, opts),
        ">"
      ])
    end
  end
end
