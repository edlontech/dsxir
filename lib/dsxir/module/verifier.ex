defmodule Dsxir.Module.Verifier do
  @moduledoc false

  defmacro __before_compile__(env) do
    declared =
      env.module
      |> Dsxir.Module.Info.module()
      |> Enum.map(& &1.name)
      |> MapSet.new()

    calls =
      env.module
      |> Module.get_attribute(:dsxir_calls, [])
      |> MapSet.new()

    extras = MapSet.difference(calls, declared)

    unless MapSet.size(extras) == 0 do
      [bad | _] = MapSet.to_list(extras)

      raise %Dsxir.Errors.Invalid.Module{
        module: env.module,
        predictor: bad,
        reason: :undeclared_predictor
      }
    end

    unless Module.defines?(env.module, {:forward, 2}, :def) do
      raise %Dsxir.Errors.Invalid.Module{
        module: env.module,
        predictor: nil,
        reason: :missing_forward
      }
    end

    :ok
  end
end
