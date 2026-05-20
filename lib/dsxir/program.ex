defmodule Dsxir.Program do
  @moduledoc """
  Runtime state container for a user program.

  Carries a `Dsxir.Program.Source` describing the program's structural origin
  (a static `use Dsxir.Module`, a runtime-authored shape, etc.), a per-predictor
  `State` map, and an open metadata map populated by optimizers. Flows
  explicitly through `forward/2` and `Dsxir.Module.Runtime.call/4` — never held
  as ambient state.
  """

  alias Dsxir.Prediction
  alias Dsxir.Program.Source

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

  @enforce_keys [:source]
  defstruct [
    :source,
    predictors: %{},
    metadata: %{compiled_with: nil, score: nil, trainset_hash: nil}
  ]

  @type t :: %__MODULE__{
          source: Source.t(),
          predictors: %{atom() => State.t()},
          metadata: map()
        }

  @doc """
  Build a fresh program from either a `Dsxir.Module`-tagged module atom or an
  already-built `Dsxir.Program.Source` struct. Raises
  `Dsxir.Errors.Invalid.Module` when an atom is given that is not a
  `Dsxir.Module`.
  """
  @spec new(module() | Source.t()) :: t()
  def new(mod) when is_atom(mod), do: new(Source.Module.new!(mod))

  def new(%_{} = source) do
    names =
      source
      |> Source.predictors()
      |> Enum.map(& &1.name)

    %__MODULE__{
      source: source,
      predictors: Map.new(names, fn name -> {name, %State{}} end)
    }
  end

  @doc """
  Build a program with explicit predictor names. Accepts either a module atom
  (wrapped via `Source.Module.new!/1`) or a pre-built source struct. Used
  internally by load paths where the predictor list is taken from the artifact
  rather than the source.
  """
  @spec new(module() | Source.t(), [atom()]) :: t()
  def new(mod_or_source, predictor_names) when is_list(predictor_names) do
    source =
      case mod_or_source do
        mod when is_atom(mod) -> Source.Module.new!(mod)
        %_{} = src -> src
      end

    %__MODULE__{
      source: source,
      predictors: Map.new(predictor_names, fn name -> {name, %State{}} end)
    }
  end

  @doc """
  Build a fresh program wrapping a runtime-authored `%Dsxir.RuntimeProgram{}`.

  Constructs a `Dsxir.Program.Source.RuntimeProgram` source and seeds the
  per-predictor `State` map with one slot per node in the runtime program.
  """
  @spec from_runtime(Dsxir.RuntimeProgram.t()) :: t()
  def from_runtime(%Dsxir.RuntimeProgram{} = rp) do
    source = %Source.RuntimeProgram{runtime_program: rp}

    names = Enum.map(rp.nodes, & &1.name)

    %__MODULE__{
      source: source,
      predictors: Map.new(names, fn name -> {name, %State{}} end)
    }
  end

  @doc """
  Dispatch a forward pass through the program.

  Asks the source to execute first (via `Source.execute/4`). When the source
  returns `nil` (the static-module case), falls back to the user-defined
  `forward/2` on the underlying module.
  """
  @spec forward(t(), map(), keyword()) ::
          {t(), Prediction.t()} | {t(), {:partial, Prediction.t()}}
  def forward(%__MODULE__{source: source} = prog, inputs, opts \\ [])
      when is_map(inputs) and is_list(opts) do
    case Source.execute(source, prog, inputs, opts) do
      nil -> apply_user_forward(prog, inputs)
      result -> result
    end
  end

  defp apply_user_forward(%__MODULE__{source: %Source.Module{module: mod}} = prog, inputs) do
    mod.forward(prog, inputs)
  end

  @doc "Fetch the per-predictor `State` slot, raising if `name` is unknown."
  @spec get_state(t(), atom()) :: State.t()
  def get_state(%__MODULE__{source: source, predictors: predictors}, name) when is_atom(name) do
    case Map.fetch(predictors, name) do
      {:ok, state} ->
        state

      :error ->
        raise %Dsxir.Errors.Invalid.Module{
          module: identity_for_error(source),
          predictor: name,
          reason: :unknown_predictor
        }
    end
  end

  @doc false
  # Format a source for the `module:` field of `Dsxir.Errors.Invalid.Module`:
  # the static atom for `:module` sources, the program-id binary for
  # `:runtime` sources. Internal use only — production paths that need to
  # dispatch behaviour on the source should go through `Source.execute/4` or
  # `Source.predictors/1`.
  @spec identity_for_error(Source.t()) :: module() | binary()
  def identity_for_error(source) do
    case Source.identity(source) do
      {:module, mod, _} -> mod
      {:runtime, id, _version} -> id
    end
  end

  @doc "Replace the `State` for `name` in `prog`, returning the updated program."
  @spec put_state(t(), atom(), State.t()) :: t()
  def put_state(%__MODULE__{} = prog, name, %State{} = state) when is_atom(name) do
    %{prog | predictors: Map.put(prog.predictors, name, state)}
  end

  @doc """
  Return the static-module atom for a `Source.Module` source.

  Raises `Dsxir.Errors.Invalid.Configuration` for runtime sources — callers
  that need to dispatch behaviour on the source must go through the
  `Dsxir.Program.Source` behaviour (`Source.execute/4`, `Source.predictors/1`,
  `Source.signature_for/2`). For error-formatting use cases that just need a
  display value, use `identity_for_error/1`.
  """
  @spec identity_module(Source.t()) :: module()
  def identity_module(source) do
    case Source.identity(source) do
      {:module, mod, _} ->
        mod

      {:runtime, _id, _version} ->
        raise %Dsxir.Errors.Invalid.Configuration{
          key: :identity_module,
          value: Source.identity(source),
          reason: :runtime_source
        }
    end
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%Dsxir.Program{source: source, predictors: predictors}, opts) do
      summary =
        predictors
        |> Enum.map(fn {name, %{demos: demos}} -> {name, length(demos)} end)
        |> Enum.sort_by(fn {name, _} -> name end)

      concat([
        "#Dsxir.Program<",
        inspect(Dsxir.Program.Source.identity(source)),
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
