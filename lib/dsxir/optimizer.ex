defmodule Dsxir.Optimizer do
  @moduledoc """
  Behaviour and dispatcher for program optimizers.

  An optimizer compiles a `Dsxir.Program.t()` against a trainset under a
  `Dsxir.Metric.t()`, returning a new program plus an open `stats` map.

  Implementations declare `@behaviour Dsxir.Optimizer` and implement
  `compile/4`. Callers invoke an optimizer through `compile/5`, which performs
  argument validation and delegates to the impl module.

  The return contract is fixed across versions:

      {:ok, Dsxir.Program.t(), stats :: map()} | {:error, Exception.t()}

  `stats` is an open map. Each optimizer documents the keys it populates;
  consumers must tolerate unknown keys.
  """

  alias Dsxir.Program

  @type stats :: map()
  @type result :: {:ok, Program.t(), stats()} | {:error, Exception.t()}

  @callback compile(
              student :: Program.t(),
              trainset :: [Dsxir.Example.t()],
              metric :: nil | Dsxir.Metric.t(),
              opts :: keyword()
            ) :: result()

  @type sampler_state :: term()
  @type trial_idx :: non_neg_integer()
  @type trial_result :: %{
          trial_idx: trial_idx(),
          candidate_id: String.t() | nil,
          score: float() | nil,
          status: :ok | :error,
          stats: map() | nil,
          duration_ms: non_neg_integer(),
          error: Exception.t() | nil,
          error_class: atom() | nil,
          candidate_program: Dsxir.Program.t() | nil
        }

  @callback init_session(
              Dsxir.Program.t(),
              [Dsxir.Example.t()],
              nil | Dsxir.Metric.t(),
              keyword()
            ) ::
              {:ok, sampler_state(), planned_trials :: pos_integer() | :unknown}
              | {:error, Exception.t()}

  @callback step(
              sampler_state(),
              trial_idx(),
              Dsxir.Program.t(),
              [Dsxir.Example.t()],
              nil | Dsxir.Metric.t(),
              keyword()
            ) ::
              {:cont, sampler_state(), trial_result()}
              | {:halt, sampler_state(), reason :: term()}

  @callback serialize_state(sampler_state()) ::
              {:ok, blob :: binary(), version :: pos_integer()}
              | {:error, term()}

  @callback deserialize_state(blob :: binary(), version :: pos_integer()) ::
              {:ok, sampler_state()} | {:error, :version_mismatch | term()}

  @optional_callbacks [init_session: 4, step: 6, serialize_state: 1, deserialize_state: 2]

  @doc """
  Return `{:ok, mod}` when `mod` implements the four optional checkpointing
  callbacks as a set; otherwise `{:error, %Dsxir.Errors.Invalid.NotCheckpointable{}}`
  listing the missing arities.

  Calls `Code.ensure_loaded?/1` before `function_exported?/3` so the check works
  even if the optimizer module has not been touched in the running BEAM.
  """
  @spec checkpointable?(module()) ::
          {:ok, module()} | {:error, Dsxir.Errors.Invalid.NotCheckpointable.t()}
  def checkpointable?(mod) when is_atom(mod) do
    if Code.ensure_loaded?(mod) do
      missing =
        [init_session: 4, step: 6, serialize_state: 1, deserialize_state: 2]
        |> Enum.reject(fn {f, a} -> function_exported?(mod, f, a) end)
        |> Enum.map(fn {f, a} -> :"#{f}/#{a}" end)

      case missing do
        [] -> {:ok, mod}
        _ -> {:error, %Dsxir.Errors.Invalid.NotCheckpointable{optimizer: mod, missing: missing}}
      end
    else
      {:error,
       %Dsxir.Errors.Invalid.NotCheckpointable{optimizer: mod, missing: [:module_not_loaded]}}
    end
  end

  @doc """
  Dispatch to `impl.compile/4` with validated arguments.

  Guards: `impl` must be an atom (module), `trainset` a list, `metric` must be
  either `nil` or a 3-arity function (optimizers that do not need a metric —
  e.g. `Dsxir.Optimizer.KNNFewShot` — accept `nil`), and `opts` a keyword list
  (any list satisfies the guard; impls are expected to treat it as a keyword
  list).
  """
  @spec compile(
          module(),
          Program.t(),
          [Dsxir.Example.t()],
          nil | Dsxir.Metric.t(),
          keyword()
        ) :: result()
  def compile(impl, %Program{} = student, trainset, nil, opts)
      when is_atom(impl) and is_list(trainset) and is_list(opts) do
    impl.compile(student, trainset, nil, opts)
  end

  def compile(impl, %Program{} = student, trainset, metric, opts)
      when is_atom(impl) and is_list(trainset) and is_function(metric, 3) and is_list(opts) do
    impl.compile(student, trainset, metric, opts)
  end
end
