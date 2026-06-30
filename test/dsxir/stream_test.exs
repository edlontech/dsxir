defmodule Dsxir.StreamTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Dsxir.Prediction
  alias Dsxir.Stream.Event
  alias Dsxir.Test.Fixtures.AnswerProgram

  setup :set_mimic_global

  defp stream_to_list(opts) do
    Dsxir.Settings.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      AnswerProgram
      |> Dsxir.Program.new()
      |> Dsxir.stream(:answer, %{question: "?"}, opts)
      |> Enum.to_list()
    end)
  end

  defp field_deltas(events) do
    for %Event{type: :field_delta, field: :answer, data: data} <- events, do: data
  end

  test "stream/4 with listen: yields field deltas then the final prediction" do
    expect(Dsxir.LM.Sycophant, :generate_text, fn _config, _msgs, opts ->
      {acc, fun} = Keyword.fetch!(opts, :stream)
      acc = fun.(%Dsxir.LM.StreamChunk{type: :text_delta, data: "[[ ## answer ## ]]\n4"}, acc)
      acc = fun.(%Dsxir.LM.StreamChunk{type: :text_delta, data: "2"}, acc)
      _acc = fun.(%Dsxir.LM.StreamChunk{type: :done, data: nil}, acc)
      {:ok, "[[ ## answer ## ]]\n42", Dsxir.LM.empty_usage()}
    end)

    events = stream_to_list(listen: [:answer])

    assert Enum.join(field_deltas(events)) == "42"
    assert %Prediction{fields: %{answer: "42"}} = List.last(events)
  end

  test "stream/4 without listen: yields raw :token events then the final prediction" do
    expect(Dsxir.LM.Sycophant, :generate_text, fn _config, _msgs, opts ->
      sink = Keyword.fetch!(opts, :stream)
      sink.(%Dsxir.LM.StreamChunk{type: :text_delta, data: "[[ ## answer ## ]]\nhi"})
      sink.(%Dsxir.LM.StreamChunk{type: :done, data: nil})
      {:ok, "[[ ## answer ## ]]\nhi", Dsxir.LM.empty_usage()}
    end)

    events = stream_to_list([])

    assert "[[ ## answer ## ]]\nhi" in for(%Event{type: :token, data: d} <- events, do: d)
    assert %Prediction{fields: %{answer: "hi"}} = List.last(events)
  end

  @tag :capture_log
  test "stream/4 surfaces a forward-pass crash as a raised exception during enumeration" do
    expect(Dsxir.LM.Sycophant, :generate_text, fn _config, _msgs, _opts ->
      {:error, %Dsxir.Errors.LM.RequestFailed{model_id: "stub", status: 500}}
    end)

    assert_raise Dsxir.Errors.LM.RequestFailed, fn -> stream_to_list([]) end
  end

  test "stream/4 halts early without hanging and returns the requested prefix" do
    expect(Dsxir.LM.Sycophant, :generate_text, fn _config, _msgs, opts ->
      sink = Keyword.fetch!(opts, :stream)
      sink.(%Dsxir.LM.StreamChunk{type: :text_delta, data: "[[ ## answer ## ]]\na"})
      sink.(%Dsxir.LM.StreamChunk{type: :text_delta, data: "b"})
      sink.(%Dsxir.LM.StreamChunk{type: :done, data: nil})
      {:ok, "[[ ## answer ## ]]\nab", Dsxir.LM.empty_usage()}
    end)

    taken =
      Dsxir.Settings.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
        AnswerProgram
        |> Dsxir.Program.new()
        |> Dsxir.stream(:answer, %{question: "?"}, [])
        |> Enum.take(1)
      end)

    assert [%Event{type: :token}] = taken
  end
end
