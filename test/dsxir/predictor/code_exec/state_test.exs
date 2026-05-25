defmodule Dsxir.Predictor.CodeExec.StateTest do
  use ExUnit.Case, async: true

  alias Dsxir.Predictor.CodeExec.State

  test "push_failure appends a failed entry newest-last, carrying the Dune type" do
    state =
      %State{}
      |> State.push_failure("a = 1", "boom", :exception)
      |> State.push_failure("a = 2", "kaboom", :restricted)

    assert [
             %{code: "a = 1", error: "boom", type: :exception, ok?: false},
             %{code: "a = 2", error: "kaboom", type: :restricted, ok?: false}
           ] = state.trajectory

    refute state.done?
  end

  test "mark_success records the result and the successful code" do
    state = State.mark_success(%State{}, "a = 3", %{value: 3, inspected: "3", stdio: ""})
    assert state.done?
    assert state.code == "a = 3"
    assert state.result.value == 3
    assert [%{code: "a = 3", error: nil, type: nil, ok?: true}] = state.trajectory
  end

  test "last_type returns the uniform failure type, else :max_iters" do
    uniform =
      %State{} |> State.push_failure("a", "x", :timeout) |> State.push_failure("b", "y", :timeout)

    mixed =
      %State{}
      |> State.push_failure("a", "x", :timeout)
      |> State.push_failure("b", "y", :exception)

    assert State.last_type(uniform) == :timeout
    assert State.last_type(mixed) == :max_iters
    assert State.last_type(%State{}) == :max_iters
  end

  test "last_failure returns nil on empty state" do
    assert State.last_failure(%State{}) == nil
  end

  test "last_failure returns the last failure entry, not a subsequent success" do
    failure_entry = %{code: "a = 1", error: "boom", type: :exception, ok?: false}

    state =
      %State{}
      |> State.push_failure("a = 1", "boom", :exception)
      |> State.mark_success("a = 2", %{value: 2, inspected: "2", stdio: ""})

    assert State.last_failure(state) == failure_entry
  end

  test "inspect renders a compact summary" do
    state =
      %State{}
      |> State.push_failure("a = 1", "boom", :exception)
      |> State.mark_success("a = 2", %{value: 2, inspected: "2", stdio: ""})

    rendered = inspect(state)
    assert rendered =~ "#Dsxir.Predictor.CodeExec.State<"
    assert rendered =~ "iter: 1"
    assert rendered =~ "done?: true"
    assert rendered =~ "trajectory: 2 attempt(s)"
  end
end
