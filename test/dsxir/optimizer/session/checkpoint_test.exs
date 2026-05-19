defmodule Dsxir.OptimizerSession.CheckpointTest do
  use ExUnit.Case, async: true

  alias Dsxir.OptimizerSession.Checkpoint

  defp fresh_checkpoint(overrides \\ []) do
    base = [
      session_id: "sess_test_1",
      optimizer: SomeOptimizer,
      optimizer_opts: [],
      trainset_hash: Checkpoint.hash_trainset([1, 2, 3]),
      program_module: MyApp.Program,
      sampler_blob: <<0, 1, 2>>,
      sampler_format: {SomeOptimizer, 1}
    ]

    Checkpoint.new(Keyword.merge(base, overrides))
  end

  test "new/1 builds a :running checkpoint with empty progress" do
    cp = fresh_checkpoint()
    assert cp.status == :running
    assert cp.progress.attempts == 0
    assert cp.progress.completed == 0
    assert cp.progress.errors == 0
    assert cp.progress.best_score == nil
  end

  test "encode/1 and decode/1 round-trip byte-for-byte" do
    cp = fresh_checkpoint()
    bin = Checkpoint.encode(cp)
    cp2 = Checkpoint.decode(bin)
    assert cp == cp2
    assert Checkpoint.encode(cp2) == bin
  end

  test "hash_trainset/1 is stable for byte-identical trainsets" do
    h1 = Checkpoint.hash_trainset([%{a: 1}, %{a: 2}])
    h2 = Checkpoint.hash_trainset([%{a: 1}, %{a: 2}])
    assert h1 == h2
  end

  test "decode/1 raises ResumeMismatch on garbage binary" do
    bin = :erlang.term_to_binary(%{not: :checkpoint})
    assert_raise Dsxir.Errors.Invalid.ResumeMismatch, fn -> Checkpoint.decode(bin) end
  end
end
