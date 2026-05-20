defmodule Dsxir.Predictor.ReActTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Dsxir.Predictor.ReAct
  alias Dsxir.Primitives.Tool

  setup :set_mimic_from_context
  setup :verify_on_exit!

  defmodule QASig do
    use Dsxir.Signature

    signature do
      instruction("Answer the user's question using the available tools.")
      input(:question, :string)
      output(:answer, :string)
    end
  end

  defp calculator do
    Tool.new(
      name: "calculator",
      description: "Evaluate an arithmetic expression and return the result.",
      parameters: Zoi.object(%{expression: Zoi.string()}),
      function: fn %{expression: e} -> Code.eval_string(e) |> elem(0) |> to_string() end
    )
  end

  defp scripted_response(thought, tool_name, tool_args) do
    args_json = Jason.encode!(tool_args)

    """
    [[ ## next_thought ## ]]
    #{thought}
    [[ ## next_tool_name ## ]]
    #{tool_name}
    [[ ## next_tool_args ## ]]
    #{args_json}
    """
  end

  defp configure_lm(responses) do
    ref = :counters.new(1, [:atomics])

    expect(Dsxir.LM.Sycophant, :generate_text, length(responses), fn _config, _messages, _opts ->
      idx = :counters.get(ref, 1)
      :counters.add(ref, 1, 1)
      {:ok, Enum.at(responses, idx), Dsxir.LM.empty_usage()}
    end)
  end

  test "loop finishes when the model emits next_tool_name: \"finish\"" do
    responses = [
      scripted_response("compute 2+2", "calculator", %{expression: "2 + 2"}),
      scripted_response("done", "finish", %{answer: "4"})
    ]

    configure_lm(responses)

    Dsxir.Settings.context([lm: {Dsxir.LM.Sycophant, [model: "fake:m"]}], fn ->
      {_prog_state, prediction} =
        ReAct.forward(
          %Dsxir.Program.State{demos: []},
          QASig,
          %{question: "2+2?"},
          tools: [calculator()],
          max_iters: 4,
          trace_name: :agent
        )

      assert prediction.fields[:answer] == "4"
      assert [_step1, _finish_step] = prediction.fields[:trajectory]
    end)
  end

  test "trace records one entry per step under the outer predictor name" do
    responses = [
      scripted_response("compute", "calculator", %{expression: "2 + 2"}),
      scripted_response("done", "finish", %{answer: "4"})
    ]

    configure_lm(responses)

    {_prog, _pred, trace} =
      Dsxir.with_trace(fn ->
        Dsxir.Settings.context([lm: {Dsxir.LM.Sycophant, [model: "fake:m"]}], fn ->
          {_, prediction} =
            ReAct.forward(
              %Dsxir.Program.State{demos: []},
              QASig,
              %{question: "2+2?"},
              tools: [calculator()],
              max_iters: 4,
              trace_name: :agent
            )

          {Dsxir.Program.new(Dsxir.Test.Fixtures.AnswerProgram), prediction}
        end)
      end)

    assert length(trace) == 2
    assert Enum.all?(trace, &match?(%Dsxir.Trace.Entry{predictor: :agent}, &1))
  end

  test "tool exceptions become observations, the loop continues" do
    raises =
      Tool.new(
        name: "boom",
        description: "Raises",
        parameters: Zoi.object(%{}),
        function: fn _ -> raise "kaboom" end
      )

    responses = [
      scripted_response("try boom", "boom", %{}),
      scripted_response("recover with calc", "calculator", %{expression: "1 + 1"}),
      scripted_response("done", "finish", %{answer: "2"})
    ]

    configure_lm(responses)

    Dsxir.Settings.context([lm: {Dsxir.LM.Sycophant, [model: "fake:m"]}], fn ->
      {_, prediction} =
        ReAct.forward(
          %Dsxir.Program.State{demos: []},
          QASig,
          %{question: "anything"},
          tools: [raises, calculator()],
          max_iters: 4,
          trace_name: :agent
        )

      assert prediction.fields[:answer] == "2"
      assert [step1 | _] = prediction.fields[:trajectory]
      assert step1.observation =~ "Execution error in boom"
    end)
  end

  test "argument validation failures use a distinguishing observation prefix" do
    responses = [
      scripted_response("call calc with bad args", "calculator", %{expression: 42}),
      scripted_response("give up", "finish", %{answer: "n/a"})
    ]

    configure_lm(responses)

    Dsxir.Settings.context([lm: {Dsxir.LM.Sycophant, [model: "fake:m"]}], fn ->
      {_, prediction} =
        ReAct.forward(
          %Dsxir.Program.State{demos: []},
          QASig,
          %{question: "anything"},
          tools: [calculator()],
          max_iters: 4,
          trace_name: :agent
        )

      assert prediction.fields[:answer] == "n/a"
      assert [step1 | _] = prediction.fields[:trajectory]
      assert String.starts_with?(step1.observation, "Argument validation error in calculator")
    end)
  end

  test "ReAct opts do not leak into Sycophant.generate_text/3" do
    expect(Sycophant, :generate_text, 1, fn _model, _messages, sycophant_opts ->
      refute Keyword.has_key?(sycophant_opts, :tools)
      refute Keyword.has_key?(sycophant_opts, :max_iters)
      refute Keyword.has_key?(sycophant_opts, :trace_name)

      {:ok,
       %Sycophant.Response{
         text: scripted_response("done", "finish", %{answer: "ok"}),
         usage: nil,
         context: %Sycophant.Context{messages: []}
       }}
    end)

    Dsxir.Settings.context([lm: {Dsxir.LM.Sycophant, [model: "fake:m"]}], fn ->
      {_, prediction} =
        ReAct.forward(
          %Dsxir.Program.State{demos: []},
          QASig,
          %{question: "anything"},
          tools: [calculator()],
          max_iters: 4,
          trace_name: :agent
        )

      assert prediction.fields[:answer] == "ok"
    end)
  end

  test "exhausting max_iters raises with the trajectory attached" do
    responses =
      Enum.map(1..3, fn _ ->
        scripted_response("keep going", "calculator", %{expression: "1 + 1"})
      end)

    configure_lm(responses)

    assert_raise Dsxir.Errors.Framework.PredictorError, fn ->
      Dsxir.Settings.context([lm: {Dsxir.LM.Sycophant, [model: "fake:m"]}], fn ->
        ReAct.forward(
          %Dsxir.Program.State{demos: []},
          QASig,
          %{question: "anything"},
          tools: [calculator()],
          max_iters: 3,
          trace_name: :agent
        )
      end)
    end
  end
end
