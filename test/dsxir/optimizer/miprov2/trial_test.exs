defmodule Dsxir.Optimizer.MIPROv2.TrialTest do
  use ExUnit.Case, async: false

  alias Dsxir.Example
  alias Dsxir.Optimizer.Cache
  alias Dsxir.Optimizer.MIPROv2.Candidates
  alias Dsxir.Optimizer.MIPROv2.Stats.Record
  alias Dsxir.Optimizer.MIPROv2.Trial
  alias Dsxir.Prediction
  alias Dsxir.Program
  alias Dsxir.Settings

  defmodule Sig do
    @moduledoc false
    use Dsxir.Signature

    signature do
      input(:question, :string)
      output(:answer, :string)
    end
  end

  defmodule StaticProg do
    @moduledoc """
    Fixture program whose `forward/2` echoes the active instruction override and
    demo count without dispatching to a real LM. This keeps trial tests free of
    network calls while still exercising `Trial.run/1`'s config application path.
    """
    use Dsxir.Module

    predictor(:answer, Dsxir.Predictor.Predict, signature: Sig)

    def forward(%Program{} = _prog, %{question: :boom}) do
      raise "intentional fixture crash"
    end

    def forward(%Program{} = prog, %{question: q}) do
      state = Program.get_state(prog, :answer)
      reply = "q=#{q};inst=#{state.instructions_override};demos=#{length(state.demos)}"
      {prog, Prediction.new(%{answer: reply})}
    end
  end

  setup do
    program = Program.new(StaticProg)

    candidates =
      Candidates.build(
        %{answer: nil},
        %{answer: ["proposed-instruction"]},
        %{answer: [[%Dsxir.Demo{kind: :labeled, example: example("ping", "pong")}]]}
      )

    config = %{{:answer, :instruction} => 1, {:answer, :demos} => 1}
    snapshot = Settings.snapshot()
    examples = [example("Capital of France?", "Paris")]

    {:ok,
     program: program,
     candidates: candidates,
     config: config,
     snapshot: snapshot,
     examples: examples}
  end

  defp example(q, a), do: Example.new(%{question: q, answer: a}, input_keys: [:question])

  defp ones_metric(_ex, _pred, _trace), do: 1.0

  defp trial_args(ctx, overrides) do
    Map.merge(
      %{
        program: ctx.program,
        config: ctx.config,
        candidates: ctx.candidates,
        examples: ctx.examples,
        metric: &ones_metric/3,
        cache_tid: nil,
        settings_snapshot: ctx.snapshot,
        trial_index: 0,
        batch_size: 1
      },
      overrides
    )
  end

  test "produces a Record with mean score, lm/cached counts and duration", ctx do
    record =
      Cache.with_compile_cache(true, fn tid ->
        Trial.run(trial_args(ctx, %{cache_tid: tid, trial_index: 7}))
      end)

    assert %Record{
             trial_index: 7,
             score: 1.0,
             lm_calls: 1,
             cached_calls: 0,
             duration_ms: ms
           } = record

    assert is_integer(ms) and ms >= 0
    assert record.config == ctx.config
  end

  test "applies the resolved instruction and demos to the program's predictor state", ctx do
    test_pid = self()

    metric = fn _ex, %Prediction{fields: %{answer: a}}, _trace ->
      send(test_pid, {:seen, a})
      1.0
    end

    Trial.run(trial_args(ctx, %{metric: metric}))

    assert_receive {:seen, reply}
    assert reply =~ "inst=proposed-instruction"
    assert reply =~ "demos=1"
  end

  test "repeating the same config on the same examples increments cached_calls", ctx do
    {first, second} =
      Cache.with_compile_cache(true, fn tid ->
        first = Trial.run(trial_args(ctx, %{cache_tid: tid, trial_index: 0}))
        second = Trial.run(trial_args(ctx, %{cache_tid: tid, trial_index: 1}))
        {first, second}
      end)

    assert first.lm_calls == 1
    assert first.cached_calls == 0
    assert second.lm_calls == 0
    assert second.cached_calls == 1
  end

  test "with cache disabled (nil tid) cached_calls is always zero", ctx do
    first = Trial.run(trial_args(ctx, %{cache_tid: nil, trial_index: 0}))
    second = Trial.run(trial_args(ctx, %{cache_tid: nil, trial_index: 1}))

    assert first.cached_calls == 0
    assert second.cached_calls == 0
    assert first.lm_calls == 1
    assert second.lm_calls == 1
  end

  test "examples that raise inside forward score 0.0 without aborting the batch", ctx do
    bad = Example.new(%{question: :boom, answer: "x"}, input_keys: [:question])
    examples = [example("ok", "ok"), bad]

    record = Trial.run(trial_args(ctx, %{examples: examples}))

    assert record.score == 0.5
  end
end
