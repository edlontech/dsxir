defmodule Dsxir.Adapter.ChatTest do
  use ExUnit.Case, async: true

  alias Dsxir.Adapter.Chat
  alias Dsxir.Telemetry
  alias Dsxir.Test.Fixtures.AnswerQuestion
  alias Dsxir.Test.Fixtures.RankItems
  alias Dsxir.Test.TelemetryHandler

  describe "format/4" do
    test "renders system + user messages for a single-input signature" do
      [system, user] = Chat.format(AnswerQuestion, %{question: "What is Elixir?"}, [], [])

      assert system.role == :system
      assert system.content =~ "Answer the user's question"
      assert system.content =~ "[[ ## field_name ## ]]"

      assert user.role == :user
      assert user.content =~ "[[ ## question ## ]]"
      assert user.content =~ "What is Elixir?"
    end

    test "renders typed list inputs as JSON" do
      [_system, user] =
        Chat.format(RankItems, %{query: "x", items: ["a", "b"]}, [], [])

      assert user.content =~ "[[ ## items ## ]]"
      assert user.content =~ ~s(["a","b"])
    end

    test "renders demos in marker form" do
      demo = %{question: "Capital of France?", answer: "Paris"}
      [_system, user] = Chat.format(AnswerQuestion, %{question: "What about Spain?"}, [demo], [])

      assert user.content =~ "Examples:"
      assert user.content =~ "Capital of France?"
      assert user.content =~ "Paris"
      assert user.content =~ "Now your turn:"
    end

    test "renders %Dsxir.Example{} demos by unwrapping their data map" do
      demo =
        Dsxir.Example.new(%{question: "Capital of France?", answer: "Paris"},
          input_keys: [:question]
        )

      [_system, user] = Chat.format(AnswerQuestion, %{question: "What about Spain?"}, [demo], [])

      assert user.content =~ "Capital of France?"
      assert user.content =~ "Paris"
      refute user.content =~ "null"
    end

    test "renders %Dsxir.Demo{} demos by unwrapping the wrapped example" do
      ex =
        Dsxir.Example.new(%{question: "Capital of France?", answer: "Paris"},
          input_keys: [:question]
        )

      demo = Dsxir.Demo.labeled(ex)

      [_system, user] = Chat.format(AnswerQuestion, %{question: "What about Spain?"}, [demo], [])

      assert user.content =~ "Capital of France?"
      assert user.content =~ "Paris"
      refute user.content =~ "null"
    end

    test "instruction_override replaces the signature instruction in the system prompt" do
      [system, _user] =
        Chat.format(AnswerQuestion, %{question: "What is Elixir?"}, [],
          instruction_override: "Custom override instruction."
        )

      assert system.content =~ "Custom override instruction."
      refute system.content =~ "Answer the user's question"
    end

    test "instruction_override falls back to signature instruction when nil" do
      [system, _user] =
        Chat.format(AnswerQuestion, %{question: "x"}, [], instruction_override: nil)

      assert system.content =~ "Answer the user's question"
    end

    test "instruction_override falls back to signature instruction when empty string" do
      [system, _user] =
        Chat.format(AnswerQuestion, %{question: "x"}, [], instruction_override: "")

      assert system.content =~ "Answer the user's question"
    end
  end

  describe "parse/3" do
    test "decodes a single string output field" do
      response = """
      [[ ## answer ## ]]
      Elixir is a dynamic, functional language.
      """

      assert {:ok, %{answer: "Elixir is a dynamic, functional language."}} =
               Chat.parse(AnswerQuestion, response, [])
    end

    test "decodes typed fields as JSON" do
      response = """
      [[ ## ranked ## ]]
      ["a", "b", "c"]

      [[ ## confidence ## ]]
      0.87
      """

      assert {:ok, %{ranked: ["a", "b", "c"], confidence: 0.87}} =
               Chat.parse(RankItems, response, [])
    end

    test "returns ParseError when no markers are present" do
      assert {:error, %Dsxir.Errors.Adapter.ParseError{reason: :no_markers}} =
               Chat.parse(AnswerQuestion, "just a string with no markers", [])
    end

    test "returns ParseError when a required output is missing" do
      response = "[[ ## ranked ## ]]\n[\"a\"]"

      assert {:error,
              %Dsxir.Errors.Adapter.ParseError{reason: :missing_field, field: :confidence}} =
               Chat.parse(RankItems, response, [])
    end

    test "returns ZoiValidation when a field fails Zoi parsing" do
      response = """
      [[ ## ranked ## ]]
      "not a list"

      [[ ## confidence ## ]]
      0.5
      """

      assert {:error, %Dsxir.Errors.Adapter.ZoiValidation{field: :ranked}} =
               Chat.parse(RankItems, response, [])
    end

    test "repeated marker for the same field keeps the last value (self-correction)" do
      response = """
      [[ ## answer ## ]]
      first attempt
      [[ ## answer ## ]]
      second attempt
      """

      assert {:ok, %{answer: "second attempt"}} =
               Chat.parse(Dsxir.Test.Fixtures.AnswerQuestion, response, [])
    end

    test "tolerates extra whitespace inside the marker brackets" do
      response = "[[  ##  answer  ##  ]]\nhello"

      assert {:ok, %{answer: "hello"}} =
               Chat.parse(Dsxir.Test.Fixtures.AnswerQuestion, response, [])
    end

    test "ignores undeclared markers from the LM" do
      response = """
      [[ ## reasoning ## ]]
      the model rambled here
      [[ ## answer ## ]]
      the real answer
      """

      assert {:ok, %{answer: "the real answer"}} =
               Chat.parse(Dsxir.Test.Fixtures.AnswerQuestion, response, [])
    end

    test "output field order in the response does not need to match declaration order" do
      response = """
      [[ ## confidence ## ]]
      0.5
      [[ ## ranked ## ]]
      ["a"]
      """

      assert {:ok, %{ranked: ["a"], confidence: 0.5}} =
               Chat.parse(Dsxir.Test.Fixtures.RankItems, response, [])
    end
  end

  describe "telemetry" do
    test "format/4 and parse/3 emit single events with duration and ok outcome" do
      parent = self()
      ref = make_ref()
      handler_id = {__MODULE__, ref}

      :ok =
        :telemetry.attach_many(
          handler_id,
          [Telemetry.adapter_format(), Telemetry.adapter_parse()],
          &TelemetryHandler.forward/4,
          %{parent: parent, tag: ref}
        )

      try do
        Chat.format(AnswerQuestion, %{question: "What is Elixir?"}, [], [])

        response = """
        [[ ## answer ## ]]
        Elixir is a dynamic, functional language.
        """

        assert {:ok, %{answer: _}} = Chat.parse(AnswerQuestion, response, [])

        assert_receive {^ref, [:dsxir, :adapter, :format], %{duration: format_duration},
                        %{
                          adapter: Dsxir.Adapter.Chat,
                          signature: AnswerQuestion,
                          outcome: :ok
                        }},
                       200

        assert is_integer(format_duration) and format_duration >= 0

        assert_receive {^ref, [:dsxir, :adapter, :parse], %{duration: parse_duration},
                        %{
                          adapter: Dsxir.Adapter.Chat,
                          signature: AnswerQuestion,
                          outcome: :ok
                        }},
                       200

        assert is_integer(parse_duration) and parse_duration >= 0
      after
        :telemetry.detach(handler_id)
      end
    end

    test "parse/3 emits an :error outcome when the response is malformed" do
      parent = self()
      ref = make_ref()
      handler_id = {__MODULE__, ref}

      :ok =
        :telemetry.attach(
          handler_id,
          Telemetry.adapter_parse(),
          &TelemetryHandler.forward/4,
          %{parent: parent, tag: ref}
        )

      try do
        assert {:error, _} = Chat.parse(RankItems, "totally malformed, no markers", [])

        assert_receive {^ref, _, %{duration: duration},
                        %{
                          adapter: Dsxir.Adapter.Chat,
                          signature: RankItems,
                          outcome: :error
                        }},
                       200

        assert is_integer(duration) and duration >= 0
      after
        :telemetry.detach(handler_id)
      end
    end

    test "events carry settings-resolved metadata so child events inherit it" do
      parent = self()
      ref = make_ref()
      handler_id = {__MODULE__, ref}

      :ok =
        :telemetry.attach_many(
          handler_id,
          [Telemetry.adapter_format(), Telemetry.adapter_parse()],
          &TelemetryHandler.forward/4,
          %{parent: parent, tag: ref}
        )

      try do
        Dsxir.Settings.context([metadata: %{tenant_id: "t-42"}], fn ->
          Chat.format(AnswerQuestion, %{question: "x"}, [], [])
          Chat.parse(AnswerQuestion, "[[ ## answer ## ]]\nhi", [])
        end)

        assert_receive {^ref, [:dsxir, :adapter, :format], _, %{tenant_id: "t-42"}}, 200
        assert_receive {^ref, [:dsxir, :adapter, :parse], _, %{tenant_id: "t-42"}}, 200
      after
        :telemetry.detach(handler_id)
      end
    end
  end
end
