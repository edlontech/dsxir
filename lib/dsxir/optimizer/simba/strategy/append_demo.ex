defmodule Dsxir.Optimizer.SIMBA.Strategy.AppendDemo do
  @moduledoc """
  SIMBA strategy that appends one augmented demo per predictor from the top
  trajectory in a bucket. No LM call.

  Keeps the last demo per predictor name when a trace visits the same predictor
  more than once (DSPy parity: `name2demo[name] = demo` overwrites on repeat,
  then one demo per predictor is appended). Skips when the top trajectory score
  is at or below the mini-batch 10th percentile.

  Input field values whose `to_string` length exceeds `ctx.demo_input_field_maxlen`
  are sliced and suffixed with `"\\n\\t\\t... <TRUNCATED FOR BREVITY>"`.
  """

  @behaviour Dsxir.Optimizer.SIMBA.Strategy

  alias Dsxir.Demo
  alias Dsxir.Example
  alias Dsxir.Program

  @truncation_marker "\n\t\t... <TRUNCATED FOR BREVITY>"

  @impl Dsxir.Optimizer.SIMBA.Strategy
  def apply(bucket, program, ctx) do
    top = hd(bucket.records)

    if top.score <= ctx.batch_p10 do
      :skip
    else
      name2demo = build_name2demo(top.trace, ctx.demo_input_field_maxlen)
      {:ok, append_demos(program, name2demo)}
    end
  end

  defp build_name2demo(trace, maxlen) do
    Enum.reduce(trace, %{}, fn entry, acc ->
      inputs = maybe_truncate(entry.inputs, maxlen)
      data = Map.merge(inputs, entry.prediction.fields)
      example = Example.new(data, input_keys: Map.keys(entry.inputs))
      demo = Demo.bootstrapped(example, %{strategy: :append_demo})
      Map.put(acc, entry.predictor, demo)
    end)
  end

  defp maybe_truncate(inputs, maxlen) when is_integer(maxlen) and maxlen > 0 do
    Map.new(inputs, fn {k, v} ->
      str = to_string(v)

      if String.length(str) > maxlen do
        {k, String.slice(str, 0, maxlen) <> @truncation_marker}
      else
        {k, v}
      end
    end)
  end

  defp maybe_truncate(inputs, _maxlen), do: inputs

  defp append_demos(program, name2demo) do
    Enum.reduce(name2demo, program, fn {name, demo}, prog ->
      state = Program.get_state(prog, name)
      Program.put_state(prog, name, %{state | demos: state.demos ++ [demo]})
    end)
  end
end
