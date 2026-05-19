defmodule Dsxir.Optimizer.Search.Sampler do
  @moduledoc """
  Behaviour for categorical hyperparameter samplers used by `Dsxir.Optimizer.MIPROv2`
  and any other optimizer that searches a fixed categorical space.

  The space is a map from dimension key to a `{:categorical, [choices]}` tuple.
  Configs are maps from dimension key to a chosen value (typically an integer index
  into the choices list). Observations pair a config with its scalar score.

  `suggest/3` returns `n` candidate configs and the (possibly mutated) sampler state.
  `observe/2` takes a list of observations — batched, one call per `suggest` batch —
  and folds them into state. Random's `observe/2` is a no-op; TPE's updates its
  good/bad partition.
  """

  @type space :: %{required(term()) => {:categorical, [term(), ...]}}
  @type config :: %{required(term()) => term()}
  @type observation :: %{config: config(), score: float()}

  @callback init(space(), opts :: keyword()) :: state :: term()
  @callback suggest(state :: term(), history :: [observation()], n :: pos_integer()) ::
              {[config()], state :: term()}
  @callback observe(state :: term(), [observation()]) :: state :: term()
end
