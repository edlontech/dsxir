defmodule Dsxir.Metric do
  @moduledoc """
  Metric contract used by `Dsxir.Evaluate` and the `Dsxir.Optimizer` family.

  A metric is any 3-arity function:

      (Dsxir.Example.t(), Dsxir.Prediction.t(), trace :: nil | list()) ->
        number() | boolean()

  The arity is fixed across v0+. The trace argument is `nil` outside
  `Dsxir.with_trace/1` (populated by `Dsxir.with_trace/1` when that helper
  lands); metrics that ignore it accept the positional argument and discard it.

  `apply/4` is the only sanctioned way to invoke a metric. It coerces booleans
  to floats and raises `Dsxir.Errors.Invalid.Metric` on any other return value
  so callers never branch on the metric's return shape.
  """

  alias Dsxir.Errors

  @type t ::
          (Dsxir.Example.t(), Dsxir.Prediction.t(), nil | list() ->
             number() | boolean())

  @doc """
  Invoke `metric` and coerce its return into a `float()`. Booleans become
  `1.0`/`0.0`; integers and floats pass through. Any other return raises
  `Dsxir.Errors.Invalid.Metric`.
  """
  @spec apply(t(), Dsxir.Example.t(), Dsxir.Prediction.t(), nil | list()) :: float()
  def apply(metric, %Dsxir.Example{} = example, %Dsxir.Prediction{} = prediction, trace)
      when is_function(metric, 3) do
    metric.(example, prediction, trace) |> coerce(example)
  end

  defp coerce(true, _example), do: 1.0
  defp coerce(false, _example), do: 0.0
  defp coerce(n, _example) when is_integer(n), do: n * 1.0
  defp coerce(n, _example) when is_float(n), do: n

  defp coerce(other, example) do
    raise %Errors.Invalid.Metric{
      example: example,
      returned: other,
      expected: "number() | boolean()"
    }
  end
end
