defmodule Dsxir.Module.RuntimeTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Dsxir.Test.Fixtures.AnswerProgram

  setup :set_mimic_from_context

  setup do
    prior = Dsxir.Settings.snapshot()
    on_exit(fn -> :persistent_term.put({Dsxir.Settings, :globals}, prior.globals) end)
    :ok
  end

  test "call/4 routes through the declared predictor impl" do
    expect(Dsxir.LM.Sycophant, :generate_text, fn _, _, _ ->
      {:ok, "[[ ## answer ## ]]\n42", Dsxir.LM.empty_usage()}
    end)

    Dsxir.Settings.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      prog = Dsxir.Program.new(AnswerProgram)
      {prog2, pred} = AnswerProgram.forward(prog, %{question: "ultimate?"})
      assert pred[:answer] == "42"
      assert %Dsxir.Program.Source.Module{module: AnswerProgram} = prog2.source
    end)
  end

  test "call/4 raises Invalid.Module on dynamic-dispatch typo at runtime" do
    prog = Dsxir.Program.new(AnswerProgram)
    name = :no_such_predictor

    assert_raise Dsxir.Errors.Invalid.Module, fn ->
      Dsxir.Module.Runtime.call(prog, name, %{question: "x"})
    end
  end

  test "call/4 raises ArgumentError when :degraded opt is not a boolean" do
    expect(Dsxir.LM.Sycophant, :generate_text, fn _, _, _ ->
      {:ok, "[[ ## answer ## ]]\n42", Dsxir.LM.empty_usage()}
    end)

    Dsxir.Settings.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      prog = Dsxir.Program.new(AnswerProgram)

      assert_raise ArgumentError, ~r/expected :degraded opt to be a boolean/, fn ->
        Dsxir.Module.Runtime.call(prog, :answer, %{question: "x"}, degraded: "yes")
      end
    end)
  end

  test "call/4 pushes predictor name onto :path in merged opts" do
    expect(Dsxir.LM.Sycophant, :generate_text, fn _, _, _ ->
      {:ok, "no markers", Dsxir.LM.empty_usage()}
    end)

    expect(Dsxir.LM.Sycophant, :generate_object, fn _, _, _, _ ->
      {:error, %Dsxir.Errors.LM.ContextWindow{model_id: "stub"}}
    end)

    Dsxir.Settings.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      prog = Dsxir.Program.new(AnswerProgram)

      err =
        try do
          Dsxir.Module.Runtime.call(prog, :answer, %{question: "x"}, path: [:outer])
          flunk("expected FallbackExhausted")
        rescue
          e in Dsxir.Errors.Adapter.FallbackExhausted -> e
        end

      assert %Dsxir.Errors.Adapter.FallbackExhausted{path: [:outer, :answer]} = err
    end)
  end
end
