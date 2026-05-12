defmodule Dsxir.Adapter.JsonProviderQuirksTest do
  use ExUnit.Case, async: false

  alias Dsxir.Test.Fixtures.AnswerProgram

  setup do
    Mimic.copy(Dsxir.LM.Sycophant)
    :ok
  end

  test "anthropic-style: result-wrapped object surfaces as a schema mismatch and the retry succeeds" do
    {:ok, _agent} = Agent.start_link(fn -> 0 end, name: :anthropic_quirk_counter)

    Mimic.stub(Dsxir.LM.Sycophant, :generate_object, fn _, _, _, _ ->
      n = Agent.get_and_update(:anthropic_quirk_counter, fn n -> {n, n + 1} end)

      case n do
        0 -> {:ok, %{result: %{answer: "Paris"}}, Dsxir.LM.empty_usage()}
        _ -> {:ok, %{answer: "Paris"}, Dsxir.LM.empty_usage()}
      end
    end)

    {_prog, prediction} =
      Dsxir.context(
        [
          lm: {Dsxir.LM.Sycophant, [model: "anthropic:claude-3-5-sonnet"]},
          adapter: Dsxir.Adapter.Json
        ],
        fn ->
          prog = Dsxir.Program.new(AnswerProgram)
          AnswerProgram.forward(prog, %{question: "Capital of France?"})
        end
      )

    assert prediction[:answer] == "Paris"
  end

  test "openai-style: nullable on a non-nullable field surfaces the field name in the retry hint" do
    {:ok, _agent} = Agent.start_link(fn -> [] end, name: :openai_quirk_messages)
    {:ok, _counter} = Agent.start_link(fn -> 0 end, name: :openai_quirk_counter)

    Mimic.stub(Dsxir.LM.Sycophant, :generate_object, fn _, messages, _, _ ->
      Agent.update(:openai_quirk_messages, &[messages | &1])
      n = Agent.get_and_update(:openai_quirk_counter, fn n -> {n, n + 1} end)

      case n do
        0 -> {:ok, %{answer: nil}, Dsxir.LM.empty_usage()}
        _ -> {:ok, %{answer: "Paris"}, Dsxir.LM.empty_usage()}
      end
    end)

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

    call_log = Agent.get(:openai_quirk_messages, & &1) |> Enum.reverse()
    assert length(call_log) == 2

    [_first, retry_messages] = call_log
    assert length(retry_messages) > length(hd(call_log))

    corrective = List.last(retry_messages)
    assert corrective.role == :user
    assert corrective.content =~ "answer"
  end

  test "gemini-style: numeric-string on a float field raises FallbackExhausted{from: Json, to: Json}" do
    Mimic.stub(Dsxir.LM.Sycophant, :generate_object, fn _, _, _, _ ->
      {:ok, %{ranked: ["a"], confidence: "0.9"}, Dsxir.LM.empty_usage()}
    end)

    err =
      assert_raise Dsxir.Errors.Adapter.FallbackExhausted, fn ->
        Dsxir.context(
          [
            lm: {Dsxir.LM.Sycophant, [model: "google:gemini-pro"]},
            adapter: Dsxir.Adapter.Json
          ],
          fn ->
            mod = Dsxir.Test.Fixtures.RankProgram
            prog = Dsxir.Program.new(mod)
            mod.forward(prog, %{query: "q", items: ["a"]})
          end
        )
      end

    assert err.from == Dsxir.Adapter.Json
    assert err.to == Dsxir.Adapter.Json
  end
end
