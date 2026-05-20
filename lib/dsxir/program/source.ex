defmodule Dsxir.Program.Source do
  @moduledoc """
  Abstracts over a `%Dsxir.Program{}`'s structural origin.

  Static `use Dsxir.Module` programs are wrapped via `Dsxir.Program.Source.Module`.
  Runtime, data-authored programs plug into the same behaviour. The dispatcher
  and optimizer talk only to this behaviour, never to the underlying struct.
  """

  alias Dsxir.Program.OptimizableSite
  alias Dsxir.Program.PredictorDecl

  @type t :: struct()
  @type identity :: {:module, module(), nil} | {:runtime, String.t(), <<_::256>>}

  @doc "Return the normalized predictor declarations exposed by `src`."
  @callback predictors(t()) :: [PredictorDecl.t()]

  @doc "Return the signature for predictor `name` on `src`."
  @callback signature_for(t(), atom()) :: module() | Dsxir.Signature.Compiled.t()

  @doc """
  Execute the program. Returning `nil` delegates to the host program's
  `forward/2` (used by `Source.Module`); returning a tuple short-circuits
  with the produced prediction (used by `Source.RuntimeProgram`).
  """
  @callback execute(t(), Dsxir.Program.t(), map(), keyword()) ::
              {Dsxir.Program.t(), Dsxir.Prediction.t()}
              | {Dsxir.Program.t(), {:partial, Dsxir.Prediction.t()}}
              | nil

  @doc "Stable identity tuple used for hashing, display, and persistence."
  @callback identity(t()) :: identity()

  @doc "Enumerate predictor sites eligible for optimizer demo writes."
  @callback optimizable_sites(t()) :: [OptimizableSite.t()]

  @doc """
  Persist `state` for predictor `name` on the source. Stateless sources (such
  as `Source.Module`) intentionally return the source unchanged — this is not
  a stub.
  """
  @callback put_predictor_state(t(), atom(), Dsxir.Program.State.t()) :: t()

  @doc "Return the JSON-safe blob written into the v2 artifact `source` slot."
  @callback to_artifact_blob(t()) :: term()

  @doc "Dispatch `predictors/1` to the impl module backing `src`."
  @spec predictors(t()) :: [PredictorDecl.t()]
  def predictors(%mod{} = src), do: mod.predictors(src)

  @doc "Dispatch `signature_for/2` to the impl module backing `src`."
  @spec signature_for(t(), atom()) :: module() | Dsxir.Signature.Compiled.t()
  def signature_for(%mod{} = src, name), do: mod.signature_for(src, name)

  @doc "Dispatch `execute/4` to the impl module backing `src`."
  @spec execute(t(), Dsxir.Program.t(), map(), keyword()) ::
          {Dsxir.Program.t(), Dsxir.Prediction.t()}
          | {Dsxir.Program.t(), {:partial, Dsxir.Prediction.t()}}
          | nil
  def execute(%mod{} = src, prog, inputs, opts \\ []),
    do: mod.execute(src, prog, inputs, opts)

  @doc "Dispatch `identity/1` to the impl module backing `src`."
  @spec identity(t()) :: identity()
  def identity(%mod{} = src), do: mod.identity(src)

  @doc "Dispatch `optimizable_sites/1` to the impl module backing `src`."
  @spec optimizable_sites(t()) :: [OptimizableSite.t()]
  def optimizable_sites(%mod{} = src), do: mod.optimizable_sites(src)

  @doc "Dispatch `put_predictor_state/3` to the impl module backing `src`."
  @spec put_predictor_state(t(), atom(), Dsxir.Program.State.t()) :: t()
  def put_predictor_state(%mod{} = src, name, state),
    do: mod.put_predictor_state(src, name, state)

  @doc "Dispatch `to_artifact_blob/1` to the impl module backing `src`."
  @spec to_artifact_blob(t()) :: term()
  def to_artifact_blob(%mod{} = src), do: mod.to_artifact_blob(src)
end
