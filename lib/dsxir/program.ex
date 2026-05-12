defmodule Dsxir.Program do
  @moduledoc """
  Runtime state container for a user program.

  Carries a reference to the user module, a per-predictor `State` map, and an
  open metadata map populated by optimizers. Flows explicitly through `forward/2`
  and `Dsxir.Module.Runtime.call/4` — never held as ambient state.
  """

  defmodule State do
    @moduledoc "Per-predictor mutable slot: demos, instruction override, signature override."
    defstruct demos: [], instructions_override: nil, signature_override: nil

    @type t :: %__MODULE__{
            demos: [Dsxir.Demo.t() | Dsxir.Example.t()],
            instructions_override: nil | String.t(),
            signature_override: nil | module()
          }
  end

  @enforce_keys [:module]
  defstruct [
    :module,
    predictors: %{},
    metadata: %{compiled_with: nil, score: nil, trainset_hash: nil}
  ]

  @type t :: %__MODULE__{
          module: module(),
          predictors: %{atom() => State.t()},
          metadata: map()
        }

  @doc """
  Build a fresh program for `user_module`. Raises
  `Dsxir.Errors.Invalid.Module` when the module is not a `Dsxir.Module`.
  """
  @spec new(module()) :: t()
  def new(user_module) when is_atom(user_module) do
    if Spark.Dsl.is?(user_module, Dsxir.Module) do
      names =
        user_module
        |> Dsxir.Module.Info.module()
        |> Enum.map(& &1.name)

      new(user_module, names)
    else
      raise %Dsxir.Errors.Invalid.Module{
        module: user_module,
        predictor: nil,
        reason: :not_a_dsxir_module
      }
    end
  end

  @doc "Build a program with explicit predictor names (used internally by load)."
  @spec new(module(), [atom()]) :: t()
  def new(user_module, predictor_names) when is_atom(user_module) and is_list(predictor_names) do
    %__MODULE__{
      module: user_module,
      predictors: Map.new(predictor_names, fn name -> {name, %State{}} end)
    }
  end

  @doc "Fetch the per-predictor `State` slot, raising if `name` is unknown."
  @spec get_state(t(), atom()) :: State.t()
  def get_state(%__MODULE__{module: module, predictors: predictors}, name) when is_atom(name) do
    case Map.fetch(predictors, name) do
      {:ok, state} ->
        state

      :error ->
        raise %Dsxir.Errors.Invalid.Module{
          module: module,
          predictor: name,
          reason: :unknown_predictor
        }
    end
  end

  @doc "Replace the `State` for `name` in `prog`, returning the updated program."
  @spec put_state(t(), atom(), State.t()) :: t()
  def put_state(%__MODULE__{} = prog, name, %State{} = state) when is_atom(name) do
    %{prog | predictors: Map.put(prog.predictors, name, state)}
  end
end
