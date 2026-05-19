defmodule Dsxir.Optimizer.Search.Random do
  @moduledoc """
  Uniform-random categorical sampler. Implementation of `Dsxir.Optimizer.Search.Sampler`.

  Each `suggest/3` call samples each dimension independently and uniformly from
  its choice list. History is ignored. `observe/2` is a no-op.

  Used as the baseline sampler and as `Dsxir.Optimizer.Search.TPE`'s cold-start
  delegate (first ~10 trials before TPE has enough mass to engage).
  """

  @behaviour Dsxir.Optimizer.Search.Sampler

  alias Dsxir.Optimizer.Search.Sampler

  defstruct space: %{}, rand_state: nil

  @type t :: %__MODULE__{
          space: Sampler.space(),
          rand_state: :rand.state() | nil
        }

  @impl Sampler
  @spec init(Sampler.space(), keyword()) :: t()
  def init(space, opts \\ []) when is_map(space) and is_list(opts) do
    seed = Keyword.get(opts, :seed, 0)
    %__MODULE__{space: space, rand_state: :rand.seed_s(:exsplus, {seed, seed + 1, seed + 2})}
  end

  @impl Sampler
  @spec suggest(t(), [Sampler.observation()], pos_integer()) :: {[Sampler.config()], t()}
  def suggest(%__MODULE__{} = state, _history, n) when is_integer(n) and n > 0 do
    {configs, new_rand} =
      Enum.reduce(1..n, {[], state.rand_state}, fn _, {acc, rs} ->
        {config, rs2} = sample_one(state.space, rs)
        {[config | acc], rs2}
      end)

    {Enum.reverse(configs), %{state | rand_state: new_rand}}
  end

  @impl Sampler
  @spec observe(t(), [Sampler.observation()]) :: t()
  def observe(%__MODULE__{} = state, _observations), do: state

  defp sample_one(space, rand_state) do
    Enum.reduce(space, {%{}, rand_state}, fn {dim_key, {:categorical, choices}}, {cfg, rs} ->
      {idx, rs2} = :rand.uniform_s(length(choices), rs)
      {Map.put(cfg, dim_key, Enum.at(choices, idx - 1)), rs2}
    end)
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%Dsxir.Optimizer.Search.Random{space: space}, _opts) do
      concat([
        "#Dsxir.Optimizer.Search.Random<dims: ",
        Integer.to_string(map_size(space)),
        ">"
      ])
    end
  end
end
