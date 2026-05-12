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

  `source` is populated only for `:bootstrapped` demos and carries the round
  index plus the trainset example index that produced the captured trace.
  """

  @enforce_keys [:example, :kind]
  defstruct [:example, :kind, source: nil]

  @type kind :: :labeled | :bootstrapped

  @type source :: nil | %{round: pos_integer(), example_index: non_neg_integer()}

  @type t :: %__MODULE__{
          example: Dsxir.Example.t(),
          kind: kind(),
          source: source()
        }

  @spec labeled(Dsxir.Example.t()) :: t()
  def labeled(%Dsxir.Example{} = ex), do: %__MODULE__{example: ex, kind: :labeled}

  @spec bootstrapped(Dsxir.Example.t(), source()) :: t()
  def bootstrapped(%Dsxir.Example{} = ex, source) when is_map(source) do
    %__MODULE__{example: ex, kind: :bootstrapped, source: source}
  end
end
