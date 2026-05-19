defmodule Dsxir.OptimizerCheckpointableTest do
  use ExUnit.Case, async: true

  alias Dsxir.Errors.Invalid.NotCheckpointable

  defmodule FullyOpted do
    @behaviour Dsxir.Optimizer
    def compile(_p, _t, _m, _o), do: {:ok, nil, %{}}
    def init_session(_p, _t, _m, _o), do: {:ok, :state, 1}
    def step(_s, _i, _p, _t, _m, _o), do: {:halt, :state, :done}
    def serialize_state(_s), do: {:ok, <<>>, 1}
    def deserialize_state(_b, _v), do: {:ok, :state}
  end

  defmodule PartiallyOpted do
    @behaviour Dsxir.Optimizer
    def compile(_p, _t, _m, _o), do: {:ok, nil, %{}}
    def init_session(_p, _t, _m, _o), do: {:ok, :state, 1}
    def step(_s, _i, _p, _t, _m, _o), do: {:halt, :state, :done}
  end

  defmodule NotOpted do
    @behaviour Dsxir.Optimizer
    def compile(_p, _t, _m, _o), do: {:ok, nil, %{}}
  end

  test "checkpointable?/1 accepts a fully-opted optimizer" do
    assert {:ok, FullyOpted} = Dsxir.Optimizer.checkpointable?(FullyOpted)
  end

  test "checkpointable?/1 lists missing callbacks for a partially-opted optimizer" do
    assert {:error, %NotCheckpointable{optimizer: PartiallyOpted, missing: missing}} =
             Dsxir.Optimizer.checkpointable?(PartiallyOpted)

    assert :"serialize_state/1" in missing
    assert :"deserialize_state/2" in missing
  end

  test "checkpointable?/1 rejects a not-opted optimizer" do
    assert {:error, %NotCheckpointable{optimizer: NotOpted}} =
             Dsxir.Optimizer.checkpointable?(NotOpted)
  end

  test "NotCheckpointable.message/1 references compile/5" do
    err = %NotCheckpointable{optimizer: NotOpted, missing: [:"step/6"]}
    assert Exception.message(err) =~ "compile/5"
  end

  test "AlreadyTerminal.message/1 includes status" do
    err = %Dsxir.Errors.Invalid.AlreadyTerminal{session_id: "sess_x", status: :completed}
    assert Exception.message(err) =~ ":completed"
  end

  test "ResumeMismatch.message/1 includes reason" do
    err = %Dsxir.Errors.Invalid.ResumeMismatch{
      session_id: "sess_x",
      reason: :sampler_version,
      expected: 2,
      got: 1
    }

    assert Exception.message(err) =~ ":sampler_version"
  end
end
