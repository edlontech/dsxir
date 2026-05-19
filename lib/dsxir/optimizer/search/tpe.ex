defmodule Dsxir.Optimizer.Search.TPE do
  @moduledoc """
  Categorical Tree-structured Parzen Estimator. Implementation of
  `Dsxir.Optimizer.Search.Sampler`.

  No tree structure (all dims unconditional). No continuous dims. Pure Elixir,
  no Nx.

  Hyperparameters (settable via `init/2` opts):

    * `:gamma` (default `0.20`) — quantile splitting good vs. bad observations.
    * `:alpha` (default `1.0`) — Laplace smoothing constant.
    * `:n_ei_candidates` (default `24`) — candidates sampled from `l` before EI scoring.
    * `:cold_start_trials` (default `10`) — uses Random until this many observations.
    * `:seed` (default `0`) — PRNG seed.
  """

  @behaviour Dsxir.Optimizer.Search.Sampler

  alias Dsxir.Optimizer.Search.Random
  alias Dsxir.Optimizer.Search.Sampler

  @default_gamma 0.20
  @default_alpha 1.0
  @default_n_ei_candidates 24
  @default_cold_start_trials 10

  defstruct space: %{},
            rand_state: nil,
            gamma: @default_gamma,
            alpha: @default_alpha,
            n_ei_candidates: @default_n_ei_candidates,
            cold_start_trials: @default_cold_start_trials,
            random_delegate: nil

  @type t :: %__MODULE__{
          space: Sampler.space(),
          rand_state: :rand.state(),
          gamma: float(),
          alpha: float(),
          n_ei_candidates: pos_integer(),
          cold_start_trials: non_neg_integer(),
          random_delegate: Random.t()
        }

  @impl Sampler
  @doc """
  Builds a TPE sampler state for the given categorical `space`.

  See module docs for supported options.
  """
  @spec init(Sampler.space(), keyword()) :: t()
  def init(space, opts \\ []) when is_map(space) and is_list(opts) do
    seed = Keyword.get(opts, :seed, 0)

    %__MODULE__{
      space: space,
      rand_state: :rand.seed_s(:exsplus, {seed, seed + 1, seed + 2}),
      gamma: Keyword.get(opts, :gamma, @default_gamma),
      alpha: Keyword.get(opts, :alpha, @default_alpha),
      n_ei_candidates: Keyword.get(opts, :n_ei_candidates, @default_n_ei_candidates),
      cold_start_trials: Keyword.get(opts, :cold_start_trials, @default_cold_start_trials),
      random_delegate: Random.init(space, seed: seed)
    }
  end

  @impl Sampler
  @doc """
  Suggests `n` candidate configs.

  While `history` has fewer than `:cold_start_trials` entries, delegates to
  `Dsxir.Optimizer.Search.Random`. Once engaged, splits history by `:gamma`
  into good/bad sets, samples `:n_ei_candidates` from the Laplace-smoothed
  categorical `l`, scores each candidate by `prod_d l_d(x_d) / g_d(x_d)`, and
  returns the top `n`.
  """
  @spec suggest(t(), [Sampler.observation()], pos_integer()) :: {[Sampler.config()], t()}
  def suggest(%__MODULE__{} = state, history, n) when is_list(history) and n > 0 do
    if length(history) < state.cold_start_trials do
      {configs, new_delegate} = Random.suggest(state.random_delegate, history, n)
      {configs, %{state | random_delegate: new_delegate}}
    else
      tpe_suggest(state, history, n)
    end
  end

  @impl Sampler
  @doc """
  No-op. TPE rebuilds its good/bad partition from the full history on each
  `suggest/3`, so there is no rolling state to update.
  """
  @spec observe(t(), [Sampler.observation()]) :: t()
  def observe(%__MODULE__{} = state, _observations), do: state

  defp tpe_suggest(state, history, n) do
    {good, bad} = split_by_gamma(history, state.gamma)
    dim_tables = build_dim_tables(state.space, good, bad, state.alpha)

    {candidates, new_rand} =
      sample_candidates(state.space, dim_tables, state.n_ei_candidates, state.rand_state)

    scored = Enum.map(candidates, &{&1, ei_score(&1, state.space, dim_tables)})

    top_n =
      scored
      |> Enum.sort_by(fn {_, s} -> -s end)
      |> Enum.take(n)
      |> Enum.map(&elem(&1, 0))

    {top_n, %{state | rand_state: new_rand}}
  end

  defp split_by_gamma(history, gamma) do
    sorted = Enum.sort_by(history, & &1.score, :desc)
    n_good = max(1, round(length(sorted) * gamma))
    {Enum.take(sorted, n_good), Enum.drop(sorted, n_good)}
  end

  defp build_dim_tables(space, good_obs, bad_obs, alpha) do
    Map.new(space, fn {dim_key, {:categorical, choices}} ->
      l_probs = dim_probs(good_obs, dim_key, choices, alpha)
      g_probs = dim_probs(bad_obs, dim_key, choices, alpha)

      index_of =
        choices
        |> Enum.with_index()
        |> Map.new()

      {dim_key, %{choices: choices, index_of: index_of, l_probs: l_probs, g_probs: g_probs}}
    end)
  end

  defp sample_candidates(space, dim_tables, n, rand_state) do
    {acc, rs} =
      Enum.reduce(1..n, {[], rand_state}, fn _, {acc, rs} ->
        {cfg, rs2} = sample_from_l(space, dim_tables, rs)
        {[cfg | acc], rs2}
      end)

    {Enum.reverse(acc), rs}
  end

  defp sample_from_l(space, dim_tables, rand_state) do
    Enum.reduce(space, {%{}, rand_state}, fn {dim_key, {:categorical, choices}}, {cfg, rs} ->
      %{l_probs: probs} = Map.fetch!(dim_tables, dim_key)
      {choice, rs2} = weighted_sample(choices, probs, rs)
      {Map.put(cfg, dim_key, choice), rs2}
    end)
  end

  defp dim_probs(observations, dim_key, choices, alpha) do
    counts =
      Enum.reduce(observations, %{}, fn obs, acc ->
        v = Map.fetch!(obs.config, dim_key)
        Map.update(acc, v, 1, &(&1 + 1))
      end)

    k = length(choices)
    total = length(observations) + alpha * k

    Enum.map(choices, fn c ->
      (Map.get(counts, c, 0) + alpha) / total
    end)
  end

  defp weighted_sample(choices, probs, rand_state) do
    {u, rs2} = :rand.uniform_s(rand_state)

    {choice, _} =
      choices
      |> Enum.zip(probs)
      |> Enum.reduce_while({List.last(choices), 0.0}, fn {c, p}, {_, acc} ->
        next = acc + p
        if u <= next, do: {:halt, {c, next}}, else: {:cont, {c, next}}
      end)

    {choice, rs2}
  end

  defp ei_score(candidate, space, dim_tables) do
    Enum.reduce(space, 1.0, fn {dim_key, _}, acc ->
      %{index_of: index_of, l_probs: l_probs, g_probs: g_probs} =
        Map.fetch!(dim_tables, dim_key)

      v = Map.fetch!(candidate, dim_key)
      idx = Map.fetch!(index_of, v)
      l_p = Enum.at(l_probs, idx)
      g_p = Enum.at(g_probs, idx)
      acc * (l_p / max(g_p, 1.0e-12))
    end)
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%Dsxir.Optimizer.Search.TPE{} = state, opts) do
      concat([
        "#Dsxir.Optimizer.Search.TPE<dims: ",
        Integer.to_string(map_size(state.space)),
        ", gamma: ",
        to_doc(state.gamma, opts),
        ", alpha: ",
        to_doc(state.alpha, opts),
        ", n_ei: ",
        Integer.to_string(state.n_ei_candidates),
        ", cold_start: ",
        Integer.to_string(state.cold_start_trials),
        ">"
      ])
    end
  end
end
