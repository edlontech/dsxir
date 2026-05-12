defmodule Dsxir.Module.RuntimeCallPlugsTest do
  use ExUnit.Case, async: false

  alias Dsxir.Test.Fixtures.AnswerProgram
  alias Dsxir.Test.TelemetryHandler

  setup do
    Mimic.copy(Dsxir.LM.Sycophant)
    :ok
  end

  test "plugs run in declared order before the predictor dispatches" do
    Mimic.stub(Dsxir.LM.Sycophant, :generate_text, fn _, _, _ ->
      {:ok, "[[ ## answer ## ]]\nParis", Dsxir.LM.empty_usage()}
    end)

    parent = self()
    plug_a = fn _ctx -> send(parent, :plug_a) end
    plug_b = fn _ctx -> send(parent, :plug_b) end

    Dsxir.context(
      [
        lm: {Dsxir.LM.Sycophant, [model: "openai:gpt-4o-mini"]},
        call_plugs: [plug_a, plug_b]
      ],
      fn ->
        prog = Dsxir.Program.new(AnswerProgram)
        AnswerProgram.forward(prog, %{question: "q"})
      end
    )

    assert_receive :plug_a
    assert_receive :plug_b
  end

  test "{:halt, reason} raises Halted.Plug and skips the predictor" do
    Mimic.stub(Dsxir.LM.Sycophant, :generate_text, fn _, _, _ ->
      flunk("predictor should not have run")
    end)

    halting = fn _ctx -> {:halt, :over_quota} end

    handler_id = "halt-test-#{:erlang.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:dsxir, :predictor, :start],
        &TelemetryHandler.forward/4,
        %{parent: parent, tag: :saw_start}
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    err =
      assert_raise Dsxir.Errors.Halted.Plug, fn ->
        Dsxir.context(
          [
            lm: {Dsxir.LM.Sycophant, [model: "openai:gpt-4o-mini"]},
            call_plugs: [halting]
          ],
          fn ->
            prog = Dsxir.Program.new(AnswerProgram)
            AnswerProgram.forward(prog, %{question: "q"})
          end
        )
      end

    assert err.reason == :over_quota
    assert %Dsxir.CallContext{predictor: :answer} = err.context
    refute_receive {:saw_start, _, _, _}, 50
  end

  test "halted error carries metadata-bearing CallContext" do
    halting = fn _ctx -> {:halt, :over_quota} end

    err =
      assert_raise Dsxir.Errors.Halted.Plug, fn ->
        Dsxir.context(
          [
            lm: {Dsxir.LM.Sycophant, [model: "openai:gpt-4o-mini"]},
            call_plugs: [halting],
            metadata: %{tenant_id: "t1"}
          ],
          fn ->
            prog = Dsxir.Program.new(AnswerProgram)
            AnswerProgram.forward(prog, %{question: "q"})
          end
        )
      end

    assert err.context.metadata == %{tenant_id: "t1"}
  end

  test "non-1-arity plug raises Invalid.Configuration" do
    assert_raise Dsxir.Errors.Invalid.Configuration, fn ->
      Dsxir.context(
        [
          lm: {Dsxir.LM.Sycophant, [model: "openai:gpt-4o-mini"]},
          call_plugs: [:not_a_function]
        ],
        fn ->
          prog = Dsxir.Program.new(AnswerProgram)
          AnswerProgram.forward(prog, %{question: "q"})
        end
      )
    end
  end
end
