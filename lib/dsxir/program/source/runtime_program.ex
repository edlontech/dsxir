defmodule Dsxir.Program.Source.RuntimeProgram do
  @moduledoc "Source impl wrapping a `%Dsxir.RuntimeProgram{}` record."

  @behaviour Dsxir.Program.Source

  alias Dsxir.Program.OptimizableSite
  alias Dsxir.Program.PredictorDecl
  alias Dsxir.RuntimeProgram

  @enforce_keys [:runtime_program]
  defstruct [:runtime_program]
  @type t :: %__MODULE__{runtime_program: RuntimeProgram.t()}

  @impl true
  def predictors(%__MODULE__{runtime_program: %RuntimeProgram{nodes: nodes}}) do
    Enum.map(nodes, fn n ->
      %PredictorDecl{name: n.name, impl: n.impl, signature: n.signature}
    end)
  end

  @impl true
  def signature_for(%__MODULE__{runtime_program: %RuntimeProgram{id: id, nodes: nodes}}, name)
      when is_atom(name) do
    case Enum.find(nodes, &(&1.name == name)) do
      nil ->
        raise %Dsxir.Errors.Invalid.Module{
          module: id,
          predictor: name,
          reason: :unknown_predictor
        }

      node ->
        node.signature
    end
  end

  @impl true
  def execute(%__MODULE__{runtime_program: rp}, prog, inputs, opts) do
    Dsxir.RuntimeProgram.Executor.execute(rp, prog, inputs, opts)
  end

  @impl true
  def identity(%__MODULE__{runtime_program: %RuntimeProgram{id: id, version: version}}),
    do: {:runtime, id, version}

  @impl true
  def optimizable_sites(%__MODULE__{runtime_program: %RuntimeProgram{nodes: nodes}}) do
    Enum.map(nodes, fn n -> %OptimizableSite{name: n.name, kind: :predictor} end)
  end

  @impl true
  def put_predictor_state(%__MODULE__{} = src, _name, _state), do: src

  @impl true
  def to_artifact_blob(%__MODULE__{runtime_program: rp}) do
    RuntimeProgram.to_artifact_blob(rp)
  end

  @doc """
  Reconstruct a `Source.RuntimeProgram` from an artifact blob (the JSON-decoded
  map produced by `RuntimeProgram.to_artifact_blob/1`). Re-validates the
  resulting program; raises `Dsxir.Errors.Invalid.RuntimeProgram` on failure.
  """
  @spec from_artifact_blob(map()) :: t()
  def from_artifact_blob(%{} = blob) do
    %__MODULE__{runtime_program: RuntimeProgram.from_artifact_blob(blob)}
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%Dsxir.Program.Source.RuntimeProgram{runtime_program: rp}, _opts) do
      concat([
        "#Dsxir.Program.Source.RuntimeProgram<id: ",
        inspect(rp.id),
        ", version: ",
        Dsxir.RuntimeProgram.short_version(rp.version),
        ">"
      ])
    end
  end
end
