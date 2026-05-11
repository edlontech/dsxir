defmodule Dsxir.M1AcceptanceTest do
  @moduledoc """
  End-to-end acceptance regression net for the first feature milestone's
  deliverables. Any later milestone that breaks one of these invariants should
  fail here loudly.
  """

  use ExUnit.Case, async: false
  use Mimic

  alias Dsxir.Test.Fixtures.AnswerProgram

  setup :set_mimic_from_context

  setup do
    prior = Dsxir.Settings.snapshot()
    on_exit(fn -> :persistent_term.put({Dsxir.Settings, :globals}, prior.globals) end)
    :ok
  end

  test "1. a user module with one signature + one predictor compiles" do
    decls = Dsxir.Module.Info.module(AnswerProgram)
    assert [%Dsxir.Module.PredictorDecl{name: :answer}] = decls
    assert function_exported?(AnswerProgram, :forward, 2)
  end

  test "2. compile-time verifier catches typo'd call/3 predictor names" do
    assert_raise Dsxir.Errors.Invalid.Module, fn ->
      defmodule TypoProgram do
        use Dsxir.Module
        predictor :answer, Dsxir.Predictor.Predict, signature: Dsxir.Test.Fixtures.AnswerQuestion
        def forward(p, _), do: call(p, :ansewr, %{})
      end
    end
  end

  test "3. stubbed LM yields a Prediction whose fields pass Zoi validation" do
    expect(Dsxir.LM.Sycophant, :generate_text, fn _, _, _ ->
      {:ok, "[[ ## answer ## ]]\nElixir is a functional language."}
    end)

    Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      {_p, pred} = AnswerProgram.forward(Dsxir.Program.new(AnswerProgram), %{question: "x"})
      assert pred[:answer] == "Elixir is a functional language."
    end)
  end

  test "5. telemetry emits start/stop with predictor/signature/adapter metadata" do
    expect(Dsxir.LM.Sycophant, :generate_text, fn _, _, _ ->
      {:ok, "[[ ## answer ## ]]\nx"}
    end)

    parent = self()
    ref = make_ref()
    handler_id = {__MODULE__, ref}

    :telemetry.attach_many(
      handler_id,
      [[:dsxir, :predictor, :start], [:dsxir, :predictor, :stop]],
      fn e, meas, meta, _ -> send(parent, {ref, e, meas, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      AnswerProgram.forward(Dsxir.Program.new(AnswerProgram), %{question: "x"})
    end)

    assert_receive {^ref, [:dsxir, :predictor, :start], _,
                    %{predictor: _, signature: _, adapter: _}}

    assert_receive {^ref, [:dsxir, :predictor, :stop], %{duration: _}, _}
  end

  test "6. errors raise as typed Splode structs" do
    expect(Dsxir.LM.Sycophant, :generate_text, fn _, _, _ -> {:ok, "no markers"} end)

    Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      assert_raise Dsxir.Errors.Adapter.ParseError, fn ->
        AnswerProgram.forward(Dsxir.Program.new(AnswerProgram), %{question: "x"})
      end
    end)
  end
end
