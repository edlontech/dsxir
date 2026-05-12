defmodule Dsxir.Adapter.ChatHistoryTest do
  use ExUnit.Case, async: true

  alias Dsxir.Adapter.Chat
  alias Dsxir.Primitives.History

  defmodule HistorySig do
    use Dsxir.Signature

    signature do
      instruction "Continue the conversation."

      input :history, Dsxir.Primitives.History
      input :user_question, :string

      output :answer, :string
    end
  end

  test "format/4 inserts history messages between the system and the user prompt" do
    history =
      History.new()
      |> History.push(:user, "Earlier turn?")
      |> History.push(:assistant, "Earlier answer.")

    inputs = %{history: history, user_question: "Latest question?"}

    [system, h1, h2, user] = Chat.format(HistorySig, inputs, [], [])

    assert %Sycophant.Message{role: :system} = system
    assert %Sycophant.Message{role: :user, content: "Earlier turn?"} = h1
    assert %Sycophant.Message{role: :assistant, content: "Earlier answer."} = h2
    assert %Sycophant.Message{role: :user, content: user_body} = user
    refute user_body =~ "Earlier turn?"
    assert user_body =~ "Latest question?"
  end

  test "format/4 elides the history block from the user prompt body" do
    [_, _, %Sycophant.Message{content: body}] =
      Chat.format(
        HistorySig,
        %{
          history: History.new() |> History.push(:user, "x"),
          user_question: "y"
        },
        [],
        []
      )

    refute body =~ "[[ ## history ## ]]"
    assert body =~ "[[ ## user_question ## ]]"
  end

  test "Json adapter raises when a history input is bound" do
    assert_raise Dsxir.Errors.Invalid.Configuration,
                 ~r/history_input_unsupported/,
                 fn ->
                   Dsxir.Adapter.Json.format(
                     HistorySig,
                     %{
                       history: History.new() |> History.push(:user, "x"),
                       user_question: "y"
                     },
                     [],
                     []
                   )
                 end
  end

  test "format/4 raises when a non-history declared input is missing" do
    assert_raise KeyError, fn ->
      Chat.format(HistorySig, %{history: History.new()}, [], [])
    end
  end
end
