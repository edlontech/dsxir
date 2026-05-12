defmodule Dsxir.Primitives.HistoryTest do
  use ExUnit.Case, async: true

  alias Dsxir.Primitives.History

  test "new/1 builds with the given entries" do
    h = History.new([%{role: :user, content: "hi"}])
    assert %History{messages: [%{role: :user, content: "hi"}]} = h
  end

  test "push/3 appends in order" do
    h =
      History.new()
      |> History.push(:user, "a")
      |> History.push(:assistant, "b")

    assert %History{messages: [%{role: :user, content: "a"}, %{role: :assistant, content: "b"}]} =
             h
  end

  test "to_messages/1 maps each entry to a Sycophant.Message" do
    h =
      History.new()
      |> History.push(:system, "sys")
      |> History.push(:user, "u")
      |> History.push(:assistant, "a")

    assert [
             %Sycophant.Message{role: :system, content: "sys"},
             %Sycophant.Message{role: :user, content: "u"},
             %Sycophant.Message{role: :assistant, content: "a"}
           ] = History.to_messages(h)
  end
end
