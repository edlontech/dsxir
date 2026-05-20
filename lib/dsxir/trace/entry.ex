defmodule Dsxir.Trace.Entry do
  @moduledoc """
  One predictor invocation captured by `Dsxir.with_trace/1`.

  An entry whose resolved inputs include any nil from an upstream optional
  skip is tagged `degraded: true`. `Dsxir.Optimizer.BootstrapFewShot` excludes
  degraded entries from its demo pool by default.
  """

  @enforce_keys [:predictor, :inputs, :prediction, :demos]
  defstruct [:predictor, :inputs, :prediction, :demos, degraded: false]

  @type t :: %__MODULE__{
          predictor: atom(),
          inputs: map(),
          prediction: Dsxir.Prediction.t(),
          demos: [Dsxir.Demo.t() | Dsxir.Example.t()],
          degraded: boolean()
        }

  @type legacy_tuple ::
          {atom(), map(), Dsxir.Prediction.t(), [Dsxir.Demo.t() | Dsxir.Example.t()]}

  @doc """
  Normalise either a struct entry or a legacy 4-tuple into a struct.

  Legacy tuples wrap with `degraded: false`. The shim exists so producers
  predating the struct (or third-party callers of `Dsxir.Trace.record/1`)
  continue to work without modification.
  """
  @spec from(t() | legacy_tuple()) :: t()
  def from(%__MODULE__{} = entry), do: entry

  def from({name, inputs, prediction, demos})
      when is_atom(name) and is_map(inputs) and is_list(demos) do
    %__MODULE__{
      predictor: name,
      inputs: inputs,
      prediction: prediction,
      demos: demos,
      degraded: false
    }
  end
end
