defmodule Dsxir.Test.Fixtures.MimicOptimizer do
  @moduledoc """
  Deterministic scripted optimizer used in OptimizerSession tests. Returns
  scores from a predeclared list and halts after the list runs out. No LM
  calls; no scoring; entirely synchronous inside `step/6`.

  ## Opts shape

      [scripted_scores: [0.6, 0.7, 0.85, 0.55, 0.9], errors_at_idx: []]

  Each `step/6` call pops the head of `scripted_scores` and reports it as a
  `:cont`. When the list is empty, returns `:halt`. Indices listed in
  `:errors_at_idx` produce `:error`-status trials instead of `:ok`.
  """

  @behaviour Dsxir.Optimizer

  alias Dsxir.Program

  @impl Dsxir.Optimizer
  def compile(%Program{} = student, trainset, metric, opts) do
    {:ok, sampler, _planned} = init_session(student, trainset, metric, opts)
    do_compile(student, trainset, metric, opts, sampler, 0, nil, [])
  end

  defp do_compile(student, trainset, metric, opts, sampler, idx, best, log) do
    case step(sampler, idx, student, trainset, metric, opts) do
      {:cont, sampler2, %{status: :ok, score: s, candidate_program: cp} = trial} ->
        new_best = if best == nil or s > elem(best, 0), do: {s, cp}, else: best
        do_compile(student, trainset, metric, opts, sampler2, idx + 1, new_best, [trial | log])

      {:cont, sampler2, %{status: :error} = trial} ->
        do_compile(student, trainset, metric, opts, sampler2, idx + 1, best, [trial | log])

      {:halt, _sampler2, reason} ->
        {prog, score} =
          case best do
            nil -> {student, nil}
            {s, cp} -> {cp, s}
          end

        {:ok, prog, %{best_score: score, trials: Enum.reverse(log), reason: reason}}
    end
  end

  @impl Dsxir.Optimizer
  def init_session(_student, _trainset, _metric, opts) do
    scores = Keyword.fetch!(opts, :scripted_scores)
    planned = length(scores)

    {:ok,
     %{
       remaining: scores,
       errors_to_inject: Keyword.get(opts, :errors_at_idx, []),
       step_delay_ms: Keyword.get(opts, :step_delay_ms, 0)
     }, planned}
  end

  @impl Dsxir.Optimizer
  def step(%{remaining: []} = state, _idx, _prog, _t, _m, _opts) do
    {:halt, state, :done}
  end

  def step(
        %{remaining: [score | rest], errors_to_inject: errs, step_delay_ms: delay} = state,
        idx,
        program,
        _t,
        _m,
        _opts
      ) do
    if delay > 0, do: Process.sleep(delay)
    new_state = %{state | remaining: rest}

    trial =
      if idx in errs do
        %{
          trial_idx: idx,
          candidate_id: "scripted-error-#{idx}",
          score: nil,
          status: :error,
          stats: nil,
          duration_ms: 0,
          error: %RuntimeError{message: "scripted error at #{idx}"},
          error_class: :unknown,
          candidate_program: nil
        }
      else
        %{
          trial_idx: idx,
          candidate_id: "scripted-#{idx}",
          score: score,
          status: :ok,
          stats: %{scripted: true},
          duration_ms: 0,
          error: nil,
          error_class: nil,
          candidate_program: program
        }
      end

    {:cont, new_state, trial}
  end

  @impl Dsxir.Optimizer
  def serialize_state(state) do
    {:ok, :erlang.term_to_binary(state, [:deterministic]), 1}
  end

  @impl Dsxir.Optimizer
  def deserialize_state(blob, 1), do: {:ok, :erlang.binary_to_term(blob, [:safe])}
  def deserialize_state(_blob, _version), do: {:error, :version_mismatch}
end
