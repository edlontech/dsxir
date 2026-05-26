defmodule Dsxir.Predictor.SamplingTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Dsxir.Prediction
  alias Dsxir.Predictor.Sampling
  alias Dsxir.Program

  setup :set_mimic_global

  setup do
    Mimic.copy(Program)
    :ok
  end

  defp prog,
    do: %Program{source: %Program.Source.Module{module: Elixir.Nonexistent}, predictors: %{}}

  defp pred(score), do: %Prediction{fields: %{score: score}}
  defp reward, do: fn _inputs, %Prediction{fields: %{score: s}} -> s end

  test "returns the highest-reward attempt across n samples" do
    {:ok, agent} = Agent.start_link(fn -> [0.2, 0.9, 0.5] end)

    stub(Program, :forward, fn p, _inputs, _opts ->
      s = Agent.get_and_update(agent, fn [h | t] -> {h, t} end)
      {p, pred(s)}
    end)

    assert {_p, %Prediction{fields: %{score: 0.9}}} =
             Sampling.run(prog(), %{}, reward(), n: 3, event_name: :best_of_n, threshold: nil)
  end

  test "stops early once reward >= threshold and runs no further attempts" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)
    {:ok, agent} = Agent.start_link(fn -> [0.3, 0.95, 0.99] end)

    stub(Program, :forward, fn p, _i, _o ->
      Agent.update(calls, &(&1 + 1))
      s = Agent.get_and_update(agent, fn [h | t] -> {h, t} end)
      {p, pred(s)}
    end)

    assert {_p, %Prediction{fields: %{score: 0.95}}} =
             Sampling.run(prog(), %{}, reward(), n: 3, event_name: :best_of_n, threshold: 0.9)

    assert Agent.get(calls, & &1) == 2
  end

  test "ties keep the earlier attempt (strict >)" do
    {:ok, agent} = Agent.start_link(fn -> [0.7, 0.7] end)
    {:ok, marks} = Agent.start_link(fn -> [:first, :second] end)

    stub(Program, :forward, fn p, _i, _o ->
      s = Agent.get_and_update(agent, fn [h | t] -> {h, t} end)
      m = Agent.get_and_update(marks, fn [h | t] -> {h, t} end)
      {p, %Prediction{fields: %{score: s, mark: m}}}
    end)

    assert {_p, %Prediction{fields: %{mark: :first}}} =
             Sampling.run(prog(), %{}, reward(), n: 2, event_name: :best_of_n, threshold: nil)
  end

  test "tolerates failures up to fail_count, then re-raises wrapped" do
    {:ok, agent} = Agent.start_link(fn -> 0 end)

    stub(Program, :forward, fn _p, _i, _o ->
      Agent.update(agent, &(&1 + 1))
      raise %Dsxir.Errors.LM.RequestFailed{model_id: "m", status: 500}
    end)

    assert_raise Dsxir.Errors.Framework.PredictorError, fn ->
      Sampling.run(prog(), %{}, reward(), n: 3, event_name: :best_of_n, fail_count: 2)
    end

    assert Agent.get(agent, & &1) == 3
  end

  test "raises Invalid.Metric when reward_fn returns a non-number" do
    stub(Program, :forward, fn p, _i, _o -> {p, pred(0.5)} end)
    bad = fn _i, _p -> "not a number" end

    assert_raise Dsxir.Errors.Invalid.Metric, fn ->
      Sampling.run(prog(), %{}, bad, n: 2, event_name: :best_of_n)
    end
  end

  test "calls on_attempt with prior info and forwards returned hints to the next attempt" do
    {:ok, priors} = Agent.start_link(fn -> [] end)
    {:ok, seen_hints} = Agent.start_link(fn -> [] end)
    {:ok, scores} = Agent.start_link(fn -> [0.2, 0.4] end)

    stub(Program, :forward, fn p, _i, _o ->
      h = Dsxir.Settings.resolve(:hints, %{})
      Agent.update(seen_hints, &[h | &1])
      s = Agent.get_and_update(scores, fn [h | t] -> {h, t} end)
      {p, %Prediction{fields: %{score: s}}}
    end)

    hook = fn prior ->
      Agent.update(priors, &[prior | &1])

      case prior do
        nil -> nil
        %{} -> %{some_pred: "hint text"}
      end
    end

    Sampling.run(prog(), %{}, reward(),
      n: 2,
      event_name: :best_of_n,
      threshold: nil,
      on_attempt: hook
    )

    prior_calls = Enum.reverse(Agent.get(priors, & &1))
    assert [nil, %{pred: _, reward: 0.2, program: _, trace: _}] = prior_calls

    hints_calls = Enum.reverse(Agent.get(seen_hints, & &1))
    assert [%{} = first, %{some_pred: "hint text"}] = hints_calls
    assert map_size(first) == 0
  end

  test "injects temperature + a fresh nonce into the lm config per attempt" do
    Dsxir.Settings.context([lm: {Dsxir.LM.Sycophant, [model: "m"]}], fn ->
      {:ok, seen} = Agent.start_link(fn -> [] end)

      stub(Program, :forward, fn p, _i, _o ->
        {impl, cfg} = Dsxir.Settings.resolve(:lm)
        Agent.update(seen, &[{impl, cfg[:temperature], cfg[:_dsxir_nonce]} | &1])
        {p, pred(0.5)}
      end)

      Sampling.run(prog(), %{}, reward(), n: 2, event_name: :best_of_n, temperature: 1.0)
      entries = Agent.get(seen, & &1)
      assert length(entries) == 2
      assert Enum.all?(entries, fn {_impl, t, nonce} -> t == 1.0 and nonce != nil end)
      nonces = Enum.map(entries, fn {_, _, nonce} -> nonce end)
      assert length(Enum.uniq(nonces)) == 2
    end)
  end
end
