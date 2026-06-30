defmodule Dsxir.Adapter.Chat.StreamParserTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Dsxir.Adapter.Chat.StreamParser
  alias Dsxir.Stream.Event

  # Reference these atoms so `String.to_existing_atom/1` resolves field names the
  # parser encounters in rendered responses.
  @name_subsets [
    [:answer],
    [:rationale],
    [:summary],
    [:answer, :rationale],
    [:answer, :summary],
    [:rationale, :summary],
    [:answer, :rationale, :summary]
  ]

  defp run(chunks, listened) do
    parser = StreamParser.new(listened)

    {events, parser} =
      Enum.reduce(chunks, {[], parser}, fn chunk, {acc, parser} ->
        {events, parser} = StreamParser.push(parser, chunk)
        {acc ++ events, parser}
      end)

    {final, _parser} = StreamParser.finish(parser)
    events ++ final
  end

  defp listened_text(events, field) do
    events
    |> Enum.filter(&match?(%Event{type: :field_delta, field: ^field}, &1))
    |> Enum.map_join("", & &1.data)
  end

  describe "push/2 + finish/1" do
    test "streams a single listened field, markers and edge whitespace stripped" do
      events = run(["[[ ## ", "answer ## ]]\n", "4", "2"], [:answer])

      assert listened_text(events, :answer) == "42"
      assert Enum.all?(events, &match?(%Event{field: :answer}, &1))
    end

    test "emits nothing for fields that are not listened" do
      response = "[[ ## answer ## ]]\n42\n[[ ## rationale ## ]]\nbecause"
      events = run([response], [:rationale])

      assert listened_text(events, :rationale) == "because"
      assert listened_text(events, :answer) == ""
    end

    test "reassembles a marker split across delta boundaries" do
      events = run(["[[ ## answ", "er ", "## ]]", "\nhello"], [:answer])
      assert listened_text(events, :answer) == "hello"
    end

    test "strips the gap newline before the next field's marker" do
      events = run(["[[ ## answer ## ]]\nfoo\n[[ ## rationale ## ]]\nbar"], [:answer, :rationale])

      assert listened_text(events, :answer) == "foo"
      assert listened_text(events, :rationale) == "bar"
    end

    test "preserves interior newlines within a field value" do
      events = run(["[[ ## answer ## ]]\nline1\nline2"], [:answer])
      assert listened_text(events, :answer) == "line1\nline2"
    end

    test "emits no zero-length field deltas" do
      events = run(["[[ ## answer ## ]]\n", "  ", "\n", "x"], [:answer])

      refute Enum.any?(events, &(&1.data == ""))
      assert listened_text(events, :answer) == "x"
    end

    test "literal brackets in a value are not mistaken for a marker" do
      events = run(["[[ ## answer ## ]]\nsee [important] note"], [:answer])
      assert listened_text(events, :answer) == "see [important] note"
    end
  end

  describe "chunking invariance" do
    property "concatenated field deltas equal the trimmed value for any chunking" do
      check all(
              fields <- uniq_field_values(),
              target <- member_of(Enum.map(fields, &elem(&1, 0))),
              boundaries <- list_of(integer(1..7), min_length: 1)
            ) do
        response = render(fields)
        chunks = chunk(response, boundaries)
        events = run(chunks, [target])

        {^target, value} = List.keyfind(fields, target, 0)
        assert listened_text(events, target) == String.trim(value)
      end
    end
  end

  defp uniq_field_values do
    gen all(
          names <- member_of(@name_subsets),
          values <- list_of(value(), length: length(names))
        ) do
      Enum.zip(names, values)
    end
  end

  defp value do
    string([?a..?z, ?A..?Z, ?0..?9, ?\s, ?\n, ?., ?,], min_length: 0, max_length: 12)
  end

  defp render(fields) do
    Enum.map_join(fields, "\n", fn {name, value} -> "[[ ## #{name} ## ]]\n#{value}" end)
  end

  defp chunk("", _sizes), do: []
  defp chunk(str, []), do: [str]

  defp chunk(str, [n | rest]) do
    take = min(n, byte_size(str))
    <<piece::binary-size(^take), remaining::binary>> = str
    [piece | chunk(remaining, rest)]
  end
end
