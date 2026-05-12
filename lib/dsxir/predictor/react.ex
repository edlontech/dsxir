defmodule Dsxir.Predictor.ReAct do
  @moduledoc """
  Tool-using agent predictor. Drives a per-step `Predict` loop until the model
  emits `next_tool_name: "finish"` or `:max_iters` is reached.

  ## Declaration

      predictor :agent, Dsxir.Predictor.ReAct,
        signature: MySig,
        tools: [calculator_tool, web_search_tool],
        max_iters: 8

  ## Trace shape

  Each iteration pushes one trace entry under the outer predictor's name. The
  step `inputs` map carries the rendered `:trajectory` string plus the original
  user inputs; the step `prediction` is a `%Dsxir.Prediction{}` with
  `next_thought`, `next_tool_name`, `next_tool_args`. `Dsxir.Module.Runtime.call/4`
  additionally records the outer entry with the final prediction. Both layers
  are intentional — the outer entry is a legitimate compound demo candidate.

  ## `trace_name` and bootstrap optimization

  The default `trace_name: :react` keeps per-step entries separate from any
  user-declared predictor. Setting `trace_name:` to the same atom as the
  declared predictor (e.g. `trace_name: :agent` when the predictor is
  `:agent`) makes the step entries land in the same `demos_pool` slot as the
  outer entry under bootstrap optimization. Step-shape demos and outer-shape
  demos render differently in the prompt and the bootstrap optimizer will not
  reshape them; collision is a footgun. Keep `trace_name` distinct from any
  declared predictor name.

  ## Errors

  Tool exceptions are caught inside the loop and surfaced as
  `"Execution error in {tool}: {message}"` observations. Exhausting
  `:max_iters` raises `Dsxir.Errors.Framework.PredictorError` with the full
  trajectory attached.
  """

  @behaviour Dsxir.Predictor

  alias Dsxir.Predictor.Predict
  alias Dsxir.Primitives.Tool
  alias Dsxir.Signature.Compiled
  alias Dsxir.Signature.Field
  alias Dsxir.Signature.Runtime
  alias Dsxir.Trace

  @react_opts [:tools, :max_iters, :trace_name]

  defmodule State do
    @moduledoc false
    defstruct trajectory: [], iter: 0, done?: false, final: nil

    @type t :: %__MODULE__{
            trajectory: [map()],
            iter: non_neg_integer(),
            done?: boolean(),
            final: nil | map()
          }
  end

  @impl Dsxir.Predictor
  def augmented_outputs(_signature), do: [:trajectory]

  @impl Dsxir.Predictor
  def forward(%Dsxir.Program.State{} = pstate, signature, inputs, opts) do
    tools = Keyword.fetch!(opts, :tools)
    max_iters = Keyword.get(opts, :max_iters, 8)
    trace_name = Keyword.get(opts, :trace_name, :react)
    step_signature = step_signature(signature, tools)

    state = %State{}

    result =
      Enum.reduce_while(1..max_iters, {pstate, state}, fn iter, {pstate_acc, state_acc} ->
        run_step(
          pstate_acc,
          state_acc,
          step_signature,
          inputs,
          tools,
          iter,
          trace_name,
          opts
        )
      end)

    case result do
      {:halted, pstate_final, final_fields, trajectory} ->
        prediction = Dsxir.Prediction.new(Map.put(final_fields, :trajectory, trajectory))
        {pstate_final, prediction}

      {_pstate_final, %State{done?: false, trajectory: trajectory}} ->
        raise %Dsxir.Errors.Framework.PredictorError{
          predictor: __MODULE__,
          signature: signature,
          inner: nil,
          reason: :max_iters_exhausted,
          trajectory: trajectory
        }
    end
  end

  defp run_step(pstate, state, step_signature, inputs, tools, iter, trace_name, opts) do
    step_inputs = Map.put(inputs, :trajectory, render_trajectory(state.trajectory))

    {pstate2, step_prediction} =
      Predict.forward(pstate, step_signature, step_inputs, predict_opts(opts))

    Trace.record({trace_name, step_inputs, step_prediction, pstate.demos})

    tool_name = step_prediction.fields[:next_tool_name]
    tool_args = step_prediction.fields[:next_tool_args] || %{}

    if tool_name == "finish" do
      final_fields = Map.new(tool_args, fn {k, v} -> {to_atom_key(k), v} end)
      trajectory = state.trajectory ++ [step_entry(step_prediction, "finish", tool_args, "ok")]
      {:halt, {:halted, pstate2, final_fields, trajectory}}
    else
      observation = invoke_tool(tools, tool_name, tool_args)
      entry = step_entry(step_prediction, tool_name, tool_args, observation)
      next_state = %{state | trajectory: state.trajectory ++ [entry], iter: iter}
      {:cont, {pstate2, next_state}}
    end
  end

  defp invoke_tool(tools, name, args) do
    case Enum.find(tools, &(&1.name == name)) do
      nil ->
        "Execution error in #{name}: unknown_tool"

      %Tool{} = tool ->
        case Tool.execute(tool, args) do
          {:ok, observation} ->
            observation

          {:error, %Dsxir.Errors.Invalid.Tool{tool: t, reason: :execution_error, inner: i}} ->
            "Execution error in #{t}: #{inspect(i)}"

          {:error, %Dsxir.Errors.Invalid.Tool{tool: t, reason: :argument_validation, inner: i}} ->
            "Argument validation error in #{t}: #{inspect(i)}"
        end
    end
  end

  defp step_entry(step_prediction, tool_name, tool_args, observation) do
    %{
      thought: step_prediction.fields[:next_thought],
      tool_name: tool_name,
      tool_args: tool_args,
      observation: observation
    }
  end

  defp render_trajectory([]), do: "(no steps yet)"

  defp render_trajectory(steps) do
    steps
    |> Enum.with_index(1)
    |> Enum.map_join("\n\n", fn {step, idx} ->
      """
      Step #{idx}
        Thought: #{step.thought}
        Tool: #{step.tool_name}
        Args: #{Jason.encode!(step.tool_args)}
        Observation: #{step.observation}
      """
    end)
  end

  defp to_atom_key(k) when is_atom(k), do: k
  defp to_atom_key(k) when is_binary(k), do: String.to_existing_atom(k)

  defp predict_opts(opts), do: Keyword.drop(opts, @react_opts)

  defp step_signature(outer, tools) do
    base_fields = Runtime.inputs(outer)

    trajectory_field = %Field{
      name: :trajectory,
      type: :string,
      zoi: Zoi.string(),
      kind: :input,
      desc: "Steps taken so far, with thought / tool / args / observation per step."
    }

    next_thought = %Field{
      name: :next_thought,
      type: :string,
      zoi: Zoi.string(),
      kind: :output,
      desc: "Reasoning for the next action."
    }

    next_tool_name = %Field{
      name: :next_tool_name,
      type: :string,
      zoi: Zoi.string(),
      kind: :output,
      desc: ~s(One of the declared tool names, or "finish" to terminate.)
    }

    next_tool_args = %Field{
      name: :next_tool_args,
      type: :map,
      zoi: Zoi.any(),
      kind: :output,
      desc: "Argument map for the chosen tool. Shape matches the tool's parameters."
    }

    %Compiled{
      fields: base_fields ++ [trajectory_field, next_thought, next_tool_name, next_tool_args],
      instruction: step_instruction(outer, tools),
      source: {:react_step_of, outer}
    }
  end

  defp step_instruction(outer, tools) do
    base = Runtime.instruction(outer) || ""

    tool_block =
      Enum.map_join(tools, "\n", fn t ->
        "  - #{t.name}: #{t.description}"
      end)

    finish_block = """
      - finish: emit when you have the final answer. next_tool_args should be a
        map shaped like the declared outer outputs (e.g. %{"answer" => "..."}).
    """

    """
    #{base}

    You may call any of the declared tools on each step. Reason briefly in
    `next_thought`, choose a tool by name in `next_tool_name`, and pass its
    argument map in `next_tool_args`. When you are ready to terminate, set
    `next_tool_name` to "finish" and put the outer outputs in `next_tool_args`.

    Tools:
    #{tool_block}
    #{finish_block}
    """
  end
end
