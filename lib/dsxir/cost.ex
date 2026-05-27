defmodule Dsxir.Cost do
  @moduledoc """
  Provider-independent record of token usage and cost for LM work.

  Carries a full breakdown — input/output/cache-read/cache-write/reasoning token
  counts and their per-bucket costs, a `total_cost`, and a `currency` — plus a
  `calls` counter (`1` for a single LM call, `N` after aggregation via `merge/2`
  or `sum/1`). Token and cost fields are `nil` when the provider did not report
  them; `nil` is distinct from `0`. Mapping from a specific provider's usage
  struct lives in the corresponding `Dsxir.LM` implementation, not here.
  """

  alias Dsxir.Settings
  alias Dsxir.Telemetry

  @derive Jason.Encoder
  defstruct input_tokens: nil,
            output_tokens: nil,
            cache_read_tokens: nil,
            cache_write_tokens: nil,
            reasoning_tokens: nil,
            input_cost: nil,
            output_cost: nil,
            cache_read_cost: nil,
            cache_write_cost: nil,
            reasoning_cost: nil,
            total_cost: nil,
            currency: nil,
            calls: 0

  @type t :: %__MODULE__{
          input_tokens: non_neg_integer() | nil,
          output_tokens: non_neg_integer() | nil,
          cache_read_tokens: non_neg_integer() | nil,
          cache_write_tokens: non_neg_integer() | nil,
          reasoning_tokens: non_neg_integer() | nil,
          input_cost: float() | nil,
          output_cost: float() | nil,
          cache_read_cost: float() | nil,
          cache_write_cost: float() | nil,
          reasoning_cost: float() | nil,
          total_cost: float() | nil,
          currency: String.t() | nil,
          calls: non_neg_integer()
        }

  @numeric_fields [
    :input_tokens,
    :output_tokens,
    :cache_read_tokens,
    :cache_write_tokens,
    :reasoning_tokens,
    :input_cost,
    :output_cost,
    :cache_read_cost,
    :cache_write_cost,
    :reasoning_cost,
    :total_cost
  ]

  @doc "Additive identity: all token/cost fields `nil`, `calls: 0`."
  @spec zero() :: t()
  def zero, do: %__MODULE__{}

  @doc """
  Field-wise sum of two costs. `nil` is the additive identity per field; a field
  that is `nil` in both stays `nil`. `calls` always adds. The first non-nil
  `currency` is kept.
  """
  @spec merge(t(), t()) :: t()
  def merge(%__MODULE__{} = a, %__MODULE__{} = b) do
    merged =
      for field <- @numeric_fields,
          into: %{},
          do: {field, add(Map.get(a, field), Map.get(b, field))}

    struct(
      __MODULE__,
      Map.merge(merged, %{calls: a.calls + b.calls, currency: a.currency || b.currency})
    )
  end

  @doc "Folds a list of costs into one, seeded with `zero/0`."
  @spec sum([t()]) :: t()
  def sum(costs) when is_list(costs),
    do: Enum.reduce(costs, zero(), fn cost, acc -> merge(acc, cost) end)

  @doc """
  Flattens a cost into the numeric measurement map emitted on
  `[:dsxir, :predictor, :stop]`. Keeps the legacy keys `:tokens_in`,
  `:tokens_out`, and `:cost`; adds the cache/reasoning token breakdown.
  Values stay `nil` when unreported.
  """
  @spec to_measurements(t()) :: map()
  def to_measurements(%__MODULE__{} = cost) do
    %{
      tokens_in: cost.input_tokens,
      tokens_out: cost.output_tokens,
      cache_read_tokens: cost.cache_read_tokens,
      cache_write_tokens: cost.cache_write_tokens,
      reasoning_tokens: cost.reasoning_tokens,
      cost: cost.total_cost
    }
  end

  @doc """
  Runs `fun` and returns `{result, %Dsxir.Cost{}}` where the cost is the sum of
  every predictor call (`[:dsxir, :predictor, :stop]`) and embedding call
  (`[:dsxir, :lm, :embed, :stop]`) emitted within the block — including from
  fan-out workers that replay the `Dsxir.Settings` snapshot.

  Pushes a unique scope id onto the `:_cost_scope` stack in `Dsxir.Settings`
  (propagated to workers via `Settings.run/2`) and attaches a telemetry handler
  that accumulates matching events in an ephemeral ETS table, folded on exit.
  No long-lived process. Handler and table are always torn down, including when
  `fun` raises.
  """
  @spec track((-> result)) :: {result, t()} when result: var
  def track(fun) when is_function(fun, 0) do
    scope_id = make_ref()
    handler_id = {:dsxir_cost_track, scope_id}
    table = :ets.new(:dsxir_cost_track, [:public, :set])

    :telemetry.attach_many(
      handler_id,
      [Telemetry.predictor_stop(), Telemetry.lm_embed_stop()],
      &__MODULE__.handle_event/4,
      %{scope_id: scope_id, table: table}
    )

    parent_scopes = Settings.resolve(:_cost_scope, [])

    try do
      result = Settings.context([_cost_scope: [scope_id | parent_scopes]], fun)
      {result, collect(table)}
    after
      :telemetry.detach(handler_id)
      :ets.delete(table)
    end
  end

  @doc false
  def handle_event(_event, _measurements, metadata, %{scope_id: scope_id, table: table}) do
    with %__MODULE__{} = cost <- Map.get(metadata, :cost),
         true <- scope_id in Map.get(metadata, :_cost_scope, []) do
      :ets.insert(table, {:erlang.unique_integer([:monotonic]), cost})
    end

    :ok
  end

  defp collect(table) do
    table
    |> :ets.tab2list()
    |> Enum.map(fn {_key, cost} -> cost end)
    |> sum()
  end

  defp add(nil, nil), do: nil
  defp add(nil, b), do: b
  defp add(a, nil), do: a
  defp add(a, b), do: a + b

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(cost, opts) do
      fields =
        Enum.reject(
          [
            in: cost.input_tokens,
            out: cost.output_tokens,
            cache_read: cost.cache_read_tokens,
            cache_write: cost.cache_write_tokens,
            reasoning: cost.reasoning_tokens,
            cost: cost.total_cost
          ],
          fn {_k, v} -> is_nil(v) end
        ) ++ [calls: cost.calls]

      inner =
        container_doc("%{", fields, "}", opts, &field_doc/2,
          separator: ",",
          break: :strict
        )

      concat(["#Dsxir.Cost<", inner, ">"])
    end

    defp field_doc({k, v}, opts) do
      concat([Atom.to_string(k), ": ", to_doc(v, opts)])
    end
  end
end
