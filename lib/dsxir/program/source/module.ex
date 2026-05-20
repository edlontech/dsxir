defmodule Dsxir.Program.Source.Module do
  @moduledoc "Source impl wrapping a static `use Dsxir.Module` user module."

  @behaviour Dsxir.Program.Source

  alias Dsxir.Program.OptimizableSite
  alias Dsxir.Program.PredictorDecl

  @enforce_keys [:module]
  defstruct [:module]
  @type t :: %__MODULE__{module: module()}

  @doc """
  Wrap `mod` in a `Dsxir.Program.Source.Module`. Raises
  `Dsxir.Errors.Invalid.Module` when `mod` is not a `Dsxir.Module`.
  """
  @spec new!(module()) :: t()
  def new!(mod) when is_atom(mod) do
    if Spark.Dsl.is?(mod, Dsxir.Module) do
      %__MODULE__{module: mod}
    else
      raise %Dsxir.Errors.Invalid.Module{
        module: mod,
        predictor: nil,
        reason: :not_a_dsxir_module
      }
    end
  end

  @impl true
  def predictors(%__MODULE__{module: mod}) do
    Enum.map(Dsxir.Module.Info.module(mod), fn decl ->
      %PredictorDecl{name: decl.name, impl: decl.impl, signature: decl.signature}
    end)
  end

  @impl true
  def signature_for(%__MODULE__{module: mod}, name) do
    case Enum.find(Dsxir.Module.Info.module(mod), &(&1.name == name)) do
      nil ->
        raise %Dsxir.Errors.Invalid.Module{
          module: mod,
          predictor: name,
          reason: :unknown_predictor
        }

      decl ->
        decl.signature
    end
  end

  @impl true
  def execute(%__MODULE__{}, _prog, _inputs, _opts), do: nil

  @impl true
  def identity(%__MODULE__{module: mod}), do: {:module, mod, nil}

  @impl true
  def optimizable_sites(%__MODULE__{} = src) do
    Enum.map(predictors(src), fn d -> %OptimizableSite{name: d.name, kind: :predictor} end)
  end

  @impl true
  def put_predictor_state(%__MODULE__{} = src, _name, _state), do: src

  @impl true
  def to_artifact_blob(%__MODULE__{module: mod}), do: Atom.to_string(mod)

  @doc """
  Reconstruct a `Source.Module` from an artifact blob (a fully-qualified
  `"Elixir.<...>"` module-atom string). The module must already be loaded
  and must be a `Dsxir.Module`; otherwise raises `Dsxir.Errors.Invalid.Module`.
  Routes through `new!/1` so the Dsxir-module check fires at load time
  instead of being deferred to `predictors/1`.
  """
  @spec from_artifact_blob(String.t()) :: t()
  def from_artifact_blob(mod_str) when is_binary(mod_str) do
    new!(String.to_existing_atom(mod_str))
  end
end
