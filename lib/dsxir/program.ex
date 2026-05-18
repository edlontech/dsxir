defmodule Dsxir.Program do
  @moduledoc """
  Runtime state container for a user program.

  Carries a reference to the user module, a per-predictor `State` map, and an
  open metadata map populated by optimizers. Flows explicitly through `forward/2`
  and `Dsxir.Module.Runtime.call/4` — never held as ambient state.
  """

  defmodule State do
    @moduledoc "Per-predictor mutable slot: demos, instruction override, signature override."
    defstruct demos: [], demo_strategy: nil, instructions_override: nil, signature_override: nil

    @type t :: %__MODULE__{
            demos: [Dsxir.Demo.t() | Dsxir.Example.t()],
            demo_strategy: nil | Dsxir.DemoStrategy.t(),
            instructions_override: nil | String.t(),
            signature_override: nil | module()
          }

    defimpl Inspect do
      import Inspect.Algebra

      def inspect(%Dsxir.Program.State{} = state, _opts) do
        parts = [
          "demos: " <> Integer.to_string(length(state.demos))
        ]

        parts =
          if state.demo_strategy,
            do: parts ++ ["demo_strategy: " <> inspect(state.demo_strategy.__struct__)],
            else: parts

        parts =
          if state.instructions_override,
            do: parts ++ ["instructions_override?: true"],
            else: parts

        parts =
          if state.signature_override,
            do: parts ++ ["signature_override: " <> inspect(state.signature_override)],
            else: parts

        concat(["#Dsxir.Program.State<", Enum.join(parts, ", "), ">"])
      end
    end
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

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%Dsxir.Program{module: module, predictors: predictors}, opts) do
      summary =
        predictors
        |> Enum.map(fn {name, %{demos: demos}} -> {name, length(demos)} end)
        |> Enum.sort_by(fn {name, _} -> name end)

      concat([
        "#Dsxir.Program<",
        inspect(module),
        ", predictors: ",
        container_doc("[", summary, "]", opts, &predictor_doc/2, separator: ",", break: :strict),
        ">"
      ])
    end

    defp predictor_doc({name, demo_count}, _opts) do
      concat([Atom.to_string(name), ": ", Integer.to_string(demo_count), " demo(s)"])
    end
  end
end
