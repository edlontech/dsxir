defmodule Dsxir.Optimizer.GEPA.Individual do
  @moduledoc """
  One member of the GEPA population. Carries the delta that produced it, its
  per-example scores and feedback (positionally aligned with the pinned
  devset), and provenance.

  `id` is deterministic from `{parent_ids, delta, generation}` so the same
  inputs produce the same id across runs.
  """

  alias Dsxir.Optimizer.GEPA.Delta

  @enforce_keys [:id, :delta, :scores, :feedback, :aggregated]
  defstruct [
    :id,
    :parent_ids,
    :delta,
    :scores,
    :feedback,
    :aggregated,
    :generation,
    :born_at,
    :operator
  ]

  @type id :: String.t()
  @type predictor_feedback :: %{atom() => String.t() | nil}
  @type t :: %__MODULE__{
          id: id(),
          parent_ids: [id()],
          delta: Delta.t(),
          scores: [float() | nil],
          feedback: [predictor_feedback() | String.t() | nil],
          aggregated: float() | nil,
          generation: non_neg_integer(),
          born_at: DateTime.t(),
          operator: :seed | :mutate_instr | :mutate_demos | :crossover
        }

  @doc """
  Builds an `Individual` from a delta plus its per-example evaluation results.
  Id is derived deterministically from `{parent_ids, delta, generation}`, so
  the same inputs yield the same id across runs.
  """
  @spec new(
          Delta.t(),
          [float() | nil],
          [predictor_feedback() | String.t() | nil],
          parent_ids :: [String.t()],
          operator :: atom(),
          generation :: non_neg_integer()
        ) :: t()
  def new(%Delta{} = delta, scores, feedback, parent_ids, operator, generation)
      when is_list(scores) and is_list(feedback) and length(scores) == length(feedback) do
    %__MODULE__{
      id: gen_id(parent_ids, delta, generation),
      parent_ids: parent_ids,
      delta: delta,
      scores: scores,
      feedback: feedback,
      aggregated: aggregate(scores),
      generation: generation,
      born_at: DateTime.utc_now(),
      operator: operator
    }
  end

  defp gen_id(parent_ids, delta, generation) do
    digest = :erlang.phash2({parent_ids, delta, generation})
    "ind_" <> Integer.to_string(digest, 16)
  end

  defp aggregate(scores) do
    non_nil = Enum.reject(scores, &is_nil/1)

    case non_nil do
      [] -> nil
      _ -> Enum.sum(non_nil) / length(non_nil)
    end
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%Dsxir.Optimizer.GEPA.Individual{} = ind, opts) do
      concat([
        "#Dsxir.Optimizer.GEPA.Individual<id: ",
        to_doc(ind.id, opts),
        ", gen: ",
        Integer.to_string(ind.generation || 0),
        ", aggregated: ",
        to_doc(ind.aggregated, opts),
        ", scores: ",
        Integer.to_string(length(ind.scores)),
        ", operator: ",
        to_doc(ind.operator, opts),
        ">"
      ])
    end
  end
end
