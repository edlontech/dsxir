defmodule Dsxir.Optimizer.BootstrapFewShot.Sampler do
  @moduledoc """
  Persistent state for a `Dsxir.Optimizer.BootstrapFewShot` session.

  Holds the data that `Dsxir.OptimizerSession` needs to checkpoint and resume
  a sequential BootstrapFewShot run: the round counter, the remaining examples
  for the current round, the accumulated demos pool per predictor, the
  predictor declarations needed to compatibility-check labeled demos, the
  labeled demos already selected during phase one, a deterministic shuffle
  seed, the resolved config, and the running error counter.

  Serialized via `:erlang.term_to_binary/2` with `:deterministic` so two
  checkpoints over the same logical state are byte-identical, and deserialized
  with `:safe` to refuse atom creation from untrusted blobs.
  """

  defstruct [
    :round,
    :max_rounds,
    :examples_remaining_in_round,
    :all_examples_for_round,
    :demos_pool,
    :predictor_decls,
    :labeled_demos_slotted,
    :rng_seed,
    :config,
    :error_count
  ]

  @type indexed_example :: {Dsxir.Example.t(), non_neg_integer()}

  @type t :: %__MODULE__{
          round: pos_integer(),
          max_rounds: pos_integer(),
          examples_remaining_in_round: [indexed_example()],
          all_examples_for_round: [indexed_example()],
          demos_pool: %{atom() => [Dsxir.Demo.t()]},
          predictor_decls: [term()],
          labeled_demos_slotted: [Dsxir.Demo.t()],
          rng_seed: integer(),
          config: map(),
          error_count: non_neg_integer()
        }
end
