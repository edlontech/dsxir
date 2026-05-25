defmodule Dsxir.Predictor.ProgramOfThoughtTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Dsxir.Predictor.ProgramOfThought
  alias Dsxir.Program.State, as: PState

  defmodule QA do
    use Dsxir.Signature

    signature do
      instruction("Answer with a number.")
      input(:question, :string)
      output(:answer, :string)
    end
  end

  setup :set_mimic_from_context

  defp marker(fields) do
    Enum.map_join(fields, "\n", fn {name, value} -> "[[ ## #{name} ## ]]\n#{value}" end)
  end

  defp canned(fields) do
    {:ok, marker(fields), Dsxir.LM.empty_usage()}
  end

  defp with_lm(fun) do
    Dsxir.Settings.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fun)
  end

  test "augmented_outputs lists the extra fields" do
    assert ProgramOfThought.augmented_outputs(QA) == [:generated_code, :trajectory]
  end

  test "forward generates code, runs it, extracts the answer" do
    expect(Dsxir.LM.Sycophant, :generate_text, fn _cfg, _msgs, _opts ->
      canned(reasoning: "compute it", generated_code: "2 * 3")
    end)

    expect(Dsxir.LM.Sycophant, :generate_text, fn _cfg, _msgs, _opts ->
      canned(reasoning: "the result is six", answer: "6")
    end)

    with_lm(fn ->
      {%PState{}, pred} = ProgramOfThought.forward(%PState{}, QA, %{question: "2*3?"}, [])
      assert pred.fields.answer == "6"
      assert pred.fields.generated_code == "2 * 3"
      assert [%{ok?: true}] = pred.fields.trajectory
    end)
  end

  test "tenant_id rides both :stop and :code_exec_attempt telemetry events" do
    ref =
      :telemetry_test.attach_event_handlers(self(), [
        [:dsxir, :predictor, :stop],
        [:dsxir, :predictor, :code_exec, :attempt]
      ])

    on_exit(fn -> :telemetry.detach(ref) end)

    expect(Dsxir.LM.Sycophant, :generate_text, fn _cfg, _msgs, _opts ->
      canned(reasoning: "compute it", generated_code: "2 * 3")
    end)

    expect(Dsxir.LM.Sycophant, :generate_text, fn _cfg, _msgs, _opts ->
      canned(reasoning: "the result is six", answer: "6")
    end)

    Dsxir.Settings.context(
      [lm: {Dsxir.LM.Sycophant, [model: "stub"]}, metadata: %{tenant_id: "t-42"}, cache: false],
      fn ->
        ProgramOfThought.forward(%PState{}, QA, %{question: "2*3?"}, [])
      end
    )

    events = drain_telemetry(ref)

    stop_events =
      Enum.filter(events, fn {event, _, _} -> event == [:dsxir, :predictor, :stop] end)

    attempt_events =
      Enum.filter(events, fn {event, _, _} ->
        event == [:dsxir, :predictor, :code_exec, :attempt]
      end)

    assert stop_events != [], "expected at least one :stop event"
    assert attempt_events != [], "expected at least one :code_exec_attempt event"

    for {_, _, meta} <- stop_events do
      assert meta.tenant_id == "t-42"
    end

    for {_, _, meta} <- attempt_events do
      assert meta.tenant_id == "t-42"
    end
  end

  @tag :integration
  test "forward against real Sycophant on trivial arithmetic" do
    {%PState{}, pred} =
      Dsxir.Settings.context(
        [lm: {Dsxir.LM.Sycophant, [model: "openai:gpt-4o-mini"]}, cache: false],
        fn ->
          ProgramOfThought.forward(%PState{}, QA, %{question: "What is 6 times 7?"}, [])
        end
      )

    assert is_binary(pred.fields.answer)
    assert is_binary(pred.fields.generated_code)
    assert is_list(pred.fields.trajectory)
  end

  defp drain_telemetry(ref, acc \\ []) do
    receive do
      {event, ^ref, measurements, metadata} ->
        drain_telemetry(ref, [{event, measurements, metadata} | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end
end
