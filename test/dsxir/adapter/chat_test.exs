defmodule Dsxir.Adapter.ChatTest do
  use ExUnit.Case, async: true

  alias Dsxir.Adapter.Chat
  alias Dsxir.Test.Fixtures.AnswerQuestion
  alias Dsxir.Test.Fixtures.RankItems

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
end
