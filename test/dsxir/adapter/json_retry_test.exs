defmodule Dsxir.Adapter.JsonRetryTest do
  use ExUnit.Case, async: false

  alias Dsxir.Test.Fixtures.AnswerProgram
  alias Dsxir.Test.TelemetryHandler

  setup do
    Mimic.copy(Dsxir.LM.Sycophant)
    :ok
  end

  test "retries once on Zoi validation failure and succeeds on retry" do
    {:ok, _agent} = Agent.start_link(fn -> 0 end, name: :retry_counter)

    Mimic.stub(Dsxir.LM.Sycophant, :generate_object, fn _, _, _, _ ->
      n = Agent.get_and_update(:retry_counter, fn n -> {n, n + 1} end)

      case n do
        0 -> {:ok, %{answer: nil}, Dsxir.LM.empty_usage()}
        _ -> {:ok, %{answer: "Paris"}, Dsxir.LM.empty_usage()}
      end
    end)

    handler_id = "json-retry-#{:erlang.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:dsxir, :adapter, :fallback],
        &TelemetryHandler.forward/4,
        %{parent: parent, tag: :fallback}
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {_prog, prediction} =
      Dsxir.context(
        [
          lm: {Dsxir.LM.Sycophant, [model: "openai:gpt-4o-mini"]},
          adapter: Dsxir.Adapter.Json
        ],
        fn ->
          prog = Dsxir.Program.new(AnswerProgram)
          AnswerProgram.forward(prog, %{question: "Capital of France?"})
        end
      )

    assert prediction[:answer] == "Paris"
    assert_receive {:fallback, _, _, %{from: Dsxir.Adapter.Json, to: Dsxir.Adapter.Json}}
  end

  test "raises FallbackExhausted{from: Json, to: Json} after a second failure" do
    Mimic.stub(Dsxir.LM.Sycophant, :generate_object, fn _, _, _, _ ->
      {:ok, %{answer: nil}, Dsxir.LM.empty_usage()}
    end)

    err =
      assert_raise Dsxir.Errors.Adapter.FallbackExhausted, fn ->
        Dsxir.context(
          [
            lm: {Dsxir.LM.Sycophant, [model: "openai:gpt-4o-mini"]},
            adapter: Dsxir.Adapter.Json
          ],
          fn ->
            prog = Dsxir.Program.new(AnswerProgram)
            AnswerProgram.forward(prog, %{question: "q"})
          end
        )
      end

    assert err.from == Dsxir.Adapter.Json
    assert err.to == Dsxir.Adapter.Json
    assert %Dsxir.Errors.Adapter.ZoiValidation{} = err.last_error
  end
end
