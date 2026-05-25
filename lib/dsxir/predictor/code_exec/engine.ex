defmodule Dsxir.Predictor.CodeExec.Engine do
  @moduledoc """
  The generate -> execute -> regenerate -> extract loop shared by
  `Dsxir.Predictor.ProgramOfThought` and `Dsxir.Predictor.CodeAct`.

  Mirrors `Dsxir.Predictor.ReAct`: an `Enum.reduce_while/3` over a
  `%CodeExec.State{}`. A failed sandbox run is loop fuel for `code_regenerate`;
  exhausting `max_iters` without a success raises
  `Dsxir.Errors.Framework.CodeExecutionError`.
  """

  alias Dsxir.Prediction
  alias Dsxir.Predictor.ChainOfThought
  alias Dsxir.Predictor.CodeExec.Sandbox
  alias Dsxir.Predictor.CodeExec.Signatures
  alias Dsxir.Predictor.CodeExec.State
  alias Dsxir.Predictor.CodeExec.ToolBridge
  alias Dsxir.Settings
  alias Dsxir.Signature.Runtime
  alias Dsxir.Telemetry
  alias Dsxir.Trace

  @engine_opts [
    :max_iters,
    :exec_type,
    :trace_name,
    :tools,
    :exec_timeout,
    :max_heap_size,
    :max_reductions,
    :atom_pool_size,
    :allowlist
  ]

  @sandbox_opts [:exec_timeout, :max_heap_size, :max_reductions, :atom_pool_size, :allowlist]

  defmodule Ctx do
    @moduledoc false
    defstruct [
      :pstate,
      :signature,
      :inputs,
      :input_names,
      :trace_name,
      :tool_prelude,
      :tool_prompt,
      :sandbox_opts,
      :exec_type,
      :opts
    ]

    @type t :: %__MODULE__{
            pstate: Dsxir.Program.State.t(),
            signature: term(),
            inputs: map(),
            input_names: [atom()],
            trace_name: atom(),
            tool_prelude: String.t(),
            tool_prompt: String.t(),
            sandbox_opts: keyword(),
            exec_type: atom(),
            opts: keyword()
          }

    defimpl Inspect do
      import Inspect.Algebra

      def inspect(%Dsxir.Predictor.CodeExec.Engine.Ctx{} = ctx, _opts) do
        concat([
          "#Dsxir.Predictor.CodeExec.Engine.Ctx<exec_type: ",
          Kernel.inspect(ctx.exec_type),
          ", trace_name: ",
          Kernel.inspect(ctx.trace_name),
          ", tools?: ",
          Atom.to_string(ctx.tool_prompt != ""),
          ">"
        ])
      end
    end
  end

  @spec run(Dsxir.Program.State.t(), Runtime.signature(), map(), keyword()) ::
          {Dsxir.Program.State.t(), Prediction.t()}
  def run(%Dsxir.Program.State{} = pstate, signature, inputs, opts) do
    {token, tool_prelude, tool_prompt} = build_tools(Keyword.get(opts, :tools, []))

    input_names = Enum.map(Runtime.inputs(signature), & &1.name)

    base =
      if tool_prompt == "",
        do: [],
        else: [allowlist: Dsxir.Predictor.CodeExec.ToolAllowlist]

    sandbox_opts = Keyword.merge(base, Keyword.take(opts, @sandbox_opts))

    ctx = %Ctx{
      pstate: pstate,
      signature: signature,
      inputs: inputs,
      input_names: input_names,
      trace_name: Keyword.fetch!(opts, :trace_name),
      tool_prelude: tool_prelude,
      tool_prompt: tool_prompt,
      sandbox_opts: sandbox_opts,
      exec_type: Keyword.fetch!(opts, :exec_type),
      opts: opts
    }

    try do
      do_run(ctx)
    after
      if token, do: ToolBridge.cleanup(token)
    end
  end

  defp build_tools([]), do: {nil, "", ""}
  defp build_tools(tools), do: ToolBridge.build(tools)

  defp do_run(%Ctx{} = ctx) do
    max_iters = Keyword.fetch!(ctx.opts, :max_iters)
    bindings = Enum.map(ctx.input_names, fn name -> {name, Map.fetch!(ctx.inputs, name)} end)

    final =
      Enum.reduce_while(0..(max_iters - 1)//1, %State{}, fn iter, acc ->
        code = generate_code(ctx, iter, acc)

        start = System.monotonic_time()

        case Sandbox.eval(with_prelude(ctx.tool_prelude, code), bindings, ctx.sandbox_opts) do
          {:ok, result} ->
            emit_attempt(ctx, iter, true, nil, start)
            {:halt, State.mark_success(acc, code, result)}

          {:error, fail} ->
            emit_attempt(ctx, iter, false, fail.type, start)
            {:cont, State.push_failure(acc, code, fail.message, fail.type)}
        end
      end)

    if final.done? do
      extract_output(ctx, final)
    else
      raise Dsxir.Errors.Framework.CodeExecutionError,
        type: State.last_type(final),
        message: "exhausted #{max_iters} attempts without a successful run",
        code: final.code,
        trajectory: final.trajectory,
        path: [ctx.trace_name]
    end
  end

  defp with_prelude("", code), do: code
  defp with_prelude(prelude, code), do: prelude <> "\n" <> code

  defp generate_code(%Ctx{} = ctx, 0, _acc) do
    sig =
      with_tool_prompt(Signatures.code_generate(ctx.signature, ctx.input_names), ctx.tool_prompt)

    {_pstate, pred} =
      ChainOfThought.forward(
        ctx.pstate,
        sig,
        ctx.inputs,
        sub_opts(ctx.opts, [ctx.trace_name, :code_generate])
      )

    Trace.record({ctx.trace_name, ctx.inputs, pred, ctx.pstate.demos})
    extract_code(pred.fields.generated_code)
  end

  defp generate_code(%Ctx{} = ctx, _iter, acc) do
    last = State.last_failure(acc)

    sig =
      with_tool_prompt(
        Signatures.code_regenerate(ctx.signature, ctx.input_names),
        ctx.tool_prompt
      )

    regen_inputs = Map.merge(ctx.inputs, %{previous_code: last.code, error: last.error})

    {_pstate, pred} =
      ChainOfThought.forward(
        ctx.pstate,
        sig,
        regen_inputs,
        sub_opts(ctx.opts, [ctx.trace_name, :regenerate])
      )

    Trace.record({ctx.trace_name, regen_inputs, pred, ctx.pstate.demos})
    extract_code(pred.fields.generated_code)
  end

  @fenced_code ~r/```[a-zA-Z]*[ \t]*\r?\n(.*?)```/s

  defp extract_code(raw) when is_binary(raw) do
    case Regex.run(@fenced_code, raw, capture: :all_but_first) do
      [code] -> String.trim(code)
      nil -> String.trim(raw)
    end
  end

  defp extract_code(nil), do: ""

  defp with_tool_prompt(sig, ""), do: sig

  defp with_tool_prompt(%{instruction: instruction} = sig, tool_prompt) do
    %{sig | instruction: instruction <> "\n\n" <> tool_prompt}
  end

  defp extract_output(%Ctx{} = ctx, final) do
    sig = Signatures.generate_output(ctx.signature, ctx.input_names)

    out_inputs =
      Map.merge(ctx.inputs, %{final_code: final.code, execution_result: final.result.inspected})

    {pstate2, pred} =
      ChainOfThought.forward(
        ctx.pstate,
        sig,
        out_inputs,
        sub_opts(ctx.opts, [ctx.trace_name, :output])
      )

    Trace.record({ctx.trace_name, out_inputs, pred, ctx.pstate.demos})

    %Prediction{} = pred
    fields = Map.merge(pred.fields, %{generated_code: final.code, trajectory: final.trajectory})

    {pstate2, %{pred | fields: fields}}
  end

  defp sub_opts(opts, path_suffix) do
    opts
    |> Keyword.drop(@engine_opts)
    |> Keyword.put(:path, path_suffix)
  end

  defp emit_attempt(%Ctx{exec_type: exec_type}, iter, ok?, failure_type, start) do
    duration = System.monotonic_time() - start
    base_metadata = Settings.resolve(:metadata, %{})

    Telemetry.emit(
      Telemetry.predictor_code_exec_attempt(),
      %{iter: iter, duration_ms: System.convert_time_unit(duration, :native, :millisecond)},
      Map.merge(base_metadata, %{
        predictor: exec_type,
        exec_type: exec_type,
        ok?: ok?,
        failure_type: failure_type
      })
    )
  end
end
