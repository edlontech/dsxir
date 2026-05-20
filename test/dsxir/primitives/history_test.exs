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

  test "to_messages/1 returns role/content maps for each entry" do
    h =
      History.new()
      |> History.push(:system, "sys")
      |> History.push(:user, "u")
      |> History.push(:assistant, "a")

    assert [
             %{role: :system, content: "sys"},
             %{role: :user, content: "u"},
             %{role: :assistant, content: "a"}
           ] = History.to_messages(h)
  end
end
