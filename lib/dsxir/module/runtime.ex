defmodule Dsxir.Module.Runtime do
  @moduledoc """
  Dispatches `call(prog, :name, inputs)` from inside `forward/2` to the
  declared predictor implementation.

  Looks up `%PredictorDecl{}` by name, extracts per-predictor state from
  `prog`, runs the configured `call_plugs` in declared order, invokes
  `impl.forward/4`, puts the (possibly updated) state back, records the trace
  entry, returns `{prog', prediction}`.

  ## call_plugs

  Plugs resolved from `Dsxir.Settings.resolve(:call_plugs, [])` run before
  every predictor dispatch. Each receives a `%Dsxir.CallContext{}` and must
  return `:ok` to continue or `{:halt, reason}` to abort. A halt raises
  `Dsxir.Errors.Halted.Plug` and the predictor `forward/4` is not invoked —
  no `[:dsxir, :predictor, :start | :stop]` events are emitted for halted
  calls.
  """

  alias Dsxir.CallContext
  alias Dsxir.Program
  alias Dsxir.Program.PredictorDecl
  alias Dsxir.Program.Source
  alias Dsxir.Settings

  require Logger

  @doc """
  Dispatch a predictor call by `name` against `prog`. Runs the configured
  `call_plugs`, invokes the predictor implementation, records the trace, and
  returns the updated program with the prediction.
  """
  @spec call(Program.t(), atom(), map() | keyword(), keyword()) ::
          {Program.t(), Dsxir.Prediction.t()}
  def call(%Program{source: source} = prog, name, inputs, opts \\ [])
      when is_atom(name) do
    inputs_map = if is_list(inputs), do: Map.new(inputs), else: inputs

    case find_decl(source, name) do
      %PredictorDecl{impl: impl, signature: signature} ->
        state = Program.get_state(prog, name)
        parent_path = Keyword.get(opts, :path, [])
        nested_opts = Keyword.put(opts, :path, parent_path ++ [name])
        merged_opts = Keyword.merge(per_call_opts_from_settings(), nested_opts)

        merged_opts =
          case Settings.resolve(:hints, %{}) do
            %{^name => hint} when is_binary(hint) and hint != "" ->
              Keyword.put(merged_opts, :hint, hint)

            _ ->
              merged_opts
          end

        ctx =
          CallContext.new(
            predictor: name,
            signature: signature,
            inputs: inputs_map,
            program: prog,
            metadata: Settings.resolve(:metadata, %{}),
            opts: merged_opts
          )

        :ok = run_plugs(Settings.resolve(:call_plugs, []), ctx)

        demos_for_call = resolve_demos(state, inputs_map, name)
        state_for_call = %{state | demos: demos_for_call}
        {new_state, prediction} = impl.forward(state_for_call, signature, inputs_map, merged_opts)
        degraded? = validate_degraded_opt(Keyword.get(opts, :degraded, false))

        Dsxir.Trace.record(%Dsxir.Trace.Entry{
          predictor: name,
          inputs: inputs_map,
          prediction: prediction,
          demos: demos_for_call,
          degraded: degraded?
        })

        {Program.put_state(prog, name, new_state), prediction}

      nil ->
        raise %Dsxir.Errors.Invalid.Module{
          module: Program.identity_for_error(source),
          predictor: name,
          reason: :undeclared_predictor
        }
    end
  end

  defp validate_degraded_opt(value) when is_boolean(value), do: value

  defp validate_degraded_opt(other) do
    raise ArgumentError,
          "expected :degraded opt to be a boolean, got: #{inspect(other)}"
  end

  defp run_plugs([], _ctx), do: :ok

  defp run_plugs([plug | rest], ctx) when is_function(plug, 1) do
    case plug.(ctx) do
      {:halt, reason} ->
        raise %Dsxir.Errors.Halted.Plug{plug: plug, reason: reason, context: ctx}

      _ ->
        run_plugs(rest, ctx)
    end
  end

  defp run_plugs([bad | _], _ctx) do
    raise %Dsxir.Errors.Invalid.Configuration{
      key: :call_plugs,
      value: bad,
      reason: :not_a_1_arity_function
    }
  end

  defp find_decl(source, name) do
    source |> Source.predictors() |> Enum.find(&(&1.name == name))
  end

  defp per_call_opts_from_settings do
    adapter = Settings.resolve(:adapter)
    if adapter, do: [adapter: adapter], else: []
  end

  defp resolve_demos(%Program.State{demo_strategy: nil} = state, _inputs, _name), do: state.demos

  defp resolve_demos(
         %Program.State{demo_strategy: %Dsxir.DemoStrategy.KNN{} = strategy} = state,
         inputs,
         name
       ) do
    if state.demos != [] do
      Logger.warning(
        "Dsxir.Module.Runtime: predictor #{inspect(name)} has both static demos and demo_strategy; " <>
          "demo_strategy wins, static demos ignored"
      )

      :telemetry.execute(
        [:dsxir, :knn, :unexpected_static_demos],
        %{},
        Map.merge(
          Settings.resolve(:metadata, %{}),
          %{predictor: name, static_demo_count: length(state.demos)}
        )
      )
    end

    Dsxir.DemoStrategy.KNN.resolve(strategy, inputs, predictor: name)
  end
end
