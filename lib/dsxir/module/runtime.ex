defmodule Dsxir.Module.Runtime do
  @moduledoc """
  Dispatches `call(prog, :name, inputs)` from inside `forward/2` to the
  declared predictor implementation. Looks up `%PredictorDecl{}` by name,
  extracts per-predictor state from `prog`, invokes `impl.forward/4`, puts the
  (possibly updated) state back, returns `{prog', prediction}`.
  """

  alias Dsxir.Module.Info
  alias Dsxir.Module.PredictorDecl
  alias Dsxir.Program
  alias Dsxir.Settings

  @spec call(Program.t(), atom(), map() | keyword(), keyword()) ::
          {Program.t(), Dsxir.Prediction.t()}
  def call(%Program{module: user_module} = prog, name, inputs, opts \\ [])
      when is_atom(name) do
    inputs_map = if is_list(inputs), do: Map.new(inputs), else: inputs

    case find_decl(user_module, name) do
      %PredictorDecl{impl: impl, signature: signature} ->
        state = Program.get_state(prog, name)
        parent_path = Keyword.get(opts, :path, [])
        nested_opts = Keyword.put(opts, :path, parent_path ++ [name])
        merged_opts = Keyword.merge(per_call_opts_from_settings(), nested_opts)
        {new_state, prediction} = impl.forward(state, signature, inputs_map, merged_opts)
        Dsxir.Trace.record({name, inputs_map, prediction, state.demos})
        {Program.put_state(prog, name, new_state), prediction}

      nil ->
        raise %Dsxir.Errors.Invalid.Module{
          module: user_module,
          predictor: name,
          reason: :undeclared_predictor
        }
    end
  end

  defp find_decl(user_module, name) do
    Info.module(user_module) |> Enum.find(&(&1.name == name))
  end

  defp per_call_opts_from_settings do
    adapter = Settings.resolve(:adapter)
    if adapter, do: [adapter: adapter], else: []
  end
end
