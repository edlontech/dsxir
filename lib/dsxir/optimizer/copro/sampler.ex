defmodule Dsxir.Optimizer.COPRO.Sampler do
  @moduledoc """
  Checkpointable, pure coordinate-ascent state for a `Dsxir.Optimizer.COPRO`
  session.

  This module holds the data a COPRO run needs to checkpoint and resume, and
  the pure transitions over it. There is no IO here: proposer (LM) calls and
  evaluator calls live in the `Dsxir.Optimizer.COPRO` wrapper, which feeds the
  resulting scores into `record_trial/3` and drives `commit_round/1`,
  `enqueue_round/2`, and `dequeue/1`. This keeps the optimizer's pure-core
  criterion intact.

  COPRO is coordinate ascent over per-predictor instructions: each round
  proposes a breadth of candidate instructions per predictor, evaluates each
  candidate as a whole program (the other predictors held at their current
  committed override), and at the end of the round commits each predictor's
  strict round winner.

  Serialized via `:erlang.term_to_binary/2` with `[:deterministic]` so two
  checkpoints over the same logical state are byte-identical, and deserialized
  with `[:safe]` to refuse atom creation from untrusted blobs.
  """

  alias Dsxir.Program.PredictorDecl

  @serialize_version 1

  defstruct [
    :seed_program,
    :decls,
    :evalset,
    :total_planned_trials,
    best_overrides: %{},
    best_score: nil,
    round_best: %{},
    history: %{},
    queue: [],
    round: 0,
    attempts: 0,
    total_devset_evals: 0,
    proposer_calls: 0,
    degraded: false,
    trial_records: []
  ]

  @type predictor_name :: atom()

  @type round_best_entry :: %{instruction: String.t() | nil, score: number() | nil}

  @type history_entry :: %{
          instruction: String.t() | nil,
          score: number() | nil,
          round: non_neg_integer()
        }

  @type work_item :: %{predictor: predictor_name(), instruction: String.t(), source: atom()}

  @type t :: %__MODULE__{
          seed_program: Dsxir.Program.t(),
          decls: [PredictorDecl.t()],
          evalset: [Dsxir.Example.t()],
          total_planned_trials: non_neg_integer(),
          best_overrides: %{predictor_name() => String.t()},
          best_score: nil | float(),
          round_best: %{predictor_name() => round_best_entry()},
          history: %{predictor_name() => [history_entry()]},
          queue: [work_item()],
          round: non_neg_integer(),
          attempts: non_neg_integer(),
          total_devset_evals: non_neg_integer(),
          proposer_calls: non_neg_integer(),
          degraded: boolean(),
          trial_records: [Dsxir.Optimizer.COPRO.Stats.Record.t()]
        }

  @doc """
  Builds a sampler from a keyword of pinned fields.

  Accepts `:seed_program`, `:decls`, `:evalset`, `:total_planned_trials`, and
  optionally `:best_overrides`. Counters and accumulators default to their zero
  values. `round_best` and `history` are seeded with one entry per declared
  predictor so the transition functions never `Map.fetch!/2` a missing key.
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    decls = Keyword.fetch!(opts, :decls)
    overrides = Keyword.get(opts, :best_overrides, %{})

    %__MODULE__{
      seed_program: Keyword.fetch!(opts, :seed_program),
      decls: decls,
      evalset: Keyword.fetch!(opts, :evalset),
      total_planned_trials: Keyword.fetch!(opts, :total_planned_trials),
      best_overrides: overrides,
      best_score: nil,
      round_best:
        Map.new(decls, fn d -> {d.name, %{instruction: overrides[d.name], score: nil}} end),
      history: Map.new(decls, fn d -> {d.name, []} end),
      queue: [],
      round: 0,
      attempts: 0,
      total_devset_evals: 0
    }
  end

  @doc """
  Pops the next work item off the queue, returning `{item, sampler}` with the
  item removed, or `:empty` when the queue is exhausted.
  """
  @spec dequeue(t()) :: {work_item(), t()} | :empty
  def dequeue(%__MODULE__{queue: []}), do: :empty

  def dequeue(%__MODULE__{queue: [item | rest]} = s),
    do: {item, %{s | queue: rest}}

  @doc """
  Records the result of evaluating a dequeued `item` with the whole-program
  `score`.

  Admits the candidate as the predictor's round best only on a strict
  improvement (`score > prev`); a tie keeps the prior best. Prepends a history
  entry for the predictor, bumps `total_devset_evals` by the eval-set size, and
  increments `attempts`.
  """
  @spec record_trial(t(), work_item(), number() | nil) :: t()
  def record_trial(%__MODULE__{} = s, item, score) do
    prev = get_in(s.round_best, [item.predictor, :score])

    round_best =
      if is_number(score) and (is_nil(prev) or score > prev) do
        put_in(s.round_best, [item.predictor], %{instruction: item.instruction, score: score})
      else
        s.round_best
      end

    entry = %{instruction: item.instruction, score: score, round: s.round}
    history = Map.update!(s.history, item.predictor, &[entry | &1])

    %{
      s
      | round_best: round_best,
        history: history,
        total_devset_evals: s.total_devset_evals + length(s.evalset),
        attempts: s.attempts + 1
    }
  end

  @doc """
  Commits the current round.

  For each declared predictor, promotes its round winner into `best_overrides`
  when the winner's instruction differs from the current override and the
  winner has a numeric score. Returns `{sampler, improved_count}` where
  `improved_count` is the number of predictors whose override changed.

  `best_score` is recomputed as the max over the round's per-predictor winner
  scores. Because each candidate is evaluated as a whole program (others held
  fixed), the round's best whole-program score under the held-fixed others is
  the value carried forward. Nil scores are rejected from the max; if every
  winner score is nil (e.g. an entirely failed round) the prior `best_score` is
  kept. `round_best` is reset to the committed baseline so the next round starts
  from the freshly committed overrides.
  """
  @spec commit_round(t()) :: {t(), non_neg_integer()}
  def commit_round(%__MODULE__{} = s) do
    {overrides, improved} =
      Enum.reduce(s.decls, {s.best_overrides, 0}, fn decl, {acc, n} ->
        rb = Map.fetch!(s.round_best, decl.name)
        cur = Map.get(acc, decl.name)

        if rb.instruction != cur and is_number(rb.score) do
          {Map.put(acc, decl.name, rb.instruction), n + 1}
        else
          {acc, n}
        end
      end)

    best_score =
      s.round_best
      |> Map.values()
      |> Enum.map(& &1.score)
      |> Enum.filter(&is_number/1)
      |> case do
        [] -> s.best_score
        scores -> Enum.max(scores)
      end

    reset =
      Map.new(s.decls, fn d ->
        {d.name, %{instruction: overrides[d.name], score: best_score}}
      end)

    {%{s | best_overrides: overrides, best_score: best_score, round_best: reset}, improved}
  end

  @doc """
  Replaces the queue with `items` and increments the round index.
  """
  @spec enqueue_round(t(), [work_item()]) :: t()
  def enqueue_round(%__MODULE__{} = s, items) when is_list(items),
    do: %{s | queue: items, round: s.round + 1}

  @doc "Whether more trials remain in the planned budget."
  @spec attempts_left?(t()) :: boolean()
  def attempts_left?(%__MODULE__{} = s), do: s.attempts < s.total_planned_trials

  @doc "Encodes the sampler deterministically. Returns `{:ok, blob, version}`."
  @spec serialize_state(t()) :: {:ok, binary(), 1}
  def serialize_state(%__MODULE__{} = s),
    do: {:ok, :erlang.term_to_binary(s, [:deterministic]), @serialize_version}

  @doc """
  Decodes a sampler blob produced by `serialize_state/1`. Uses the `:safe` term
  decoder and validates the resulting struct shape.
  """
  @spec deserialize_state(binary(), pos_integer()) ::
          {:ok, t()}
          | {:error, :version_mismatch | :corrupt_blob | {:bad_sampler_shape, term()}}
  def deserialize_state(blob, @serialize_version) when is_binary(blob) do
    case :erlang.binary_to_term(blob, [:safe]) do
      %__MODULE__{} = s -> {:ok, s}
      other -> {:error, {:bad_sampler_shape, other}}
    end
  rescue
    ArgumentError -> {:error, :corrupt_blob}
  end

  def deserialize_state(_, _), do: {:error, :version_mismatch}

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%Dsxir.Optimizer.COPRO.Sampler{} = s, opts) do
      concat([
        "#Dsxir.Optimizer.COPRO.Sampler<round: ",
        Integer.to_string(s.round),
        ", attempts: ",
        Integer.to_string(s.attempts),
        "/",
        Integer.to_string(s.total_planned_trials),
        ", queue: ",
        Integer.to_string(length(s.queue)),
        ", decls: ",
        Integer.to_string(length(s.decls)),
        ", evalset: ",
        Integer.to_string(length(s.evalset)),
        ", best_score: ",
        to_doc(s.best_score, opts),
        ", proposer_calls: ",
        Integer.to_string(s.proposer_calls),
        ", degraded: ",
        to_doc(s.degraded, opts),
        ">"
      ])
    end
  end
end
