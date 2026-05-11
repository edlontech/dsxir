defmodule Dsxir.ExampleTest do
  use ExUnit.Case, async: true

  test "new/2 + with_inputs/2 partitions data into inputs and labels" do
    ex =
      %{transcript: "...", action_items: [], decisions: []}
      |> Dsxir.Example.new()
      |> Dsxir.Example.with_inputs([:transcript])

    assert Dsxir.Example.inputs(ex) == %{transcript: "..."}
    assert Dsxir.Example.labels(ex) == %{action_items: [], decisions: []}
  end

  test "new/2 with :input_keys opt seeds the partition" do
    ex = Dsxir.Example.new(%{q: "x", a: "y"}, input_keys: [:q])
    assert Dsxir.Example.inputs(ex) == %{q: "x"}
    assert Dsxir.Example.labels(ex) == %{a: "y"}
  end
end
