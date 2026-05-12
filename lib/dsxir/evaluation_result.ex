defmodule Dsxir.EvaluationResult do
  @moduledoc """
  Result of a single `Dsxir.Evaluate.run/2` invocation.

    * `:score` — `avg(metric_value) * 100`, rounded to 1 decimal place.
    * `:results` — one row per devset entry, in input order. Successful rows
      carry `metric: float()`; errored rows carry `metric: nil, error: %Exception{}`.
    * `:errors` — `%{count: non_neg_integer(), by_class: %{atom() => non_neg_integer()}}`.
      `:by_class` keys are the splode error class atoms (`:adapter`, `:lm`,
      `:invalid`, `:halted`, `:framework`, `:unknown`).

  Subscribers branch on `nil` vs. populated; the `:errors` map is always
  present, even when zero errors occurred (then `count: 0, by_class: %{}`).
  """

  defstruct score: 0.0, results: [], errors: %{count: 0, by_class: %{}}

  @type row :: %{
          example: Dsxir.Example.t(),
          prediction: nil | Dsxir.Prediction.t(),
          metric: nil | float(),
          error: nil | Exception.t()
        }

  @type t :: %__MODULE__{
          score: float(),
          results: [row()],
          errors: %{count: non_neg_integer(), by_class: %{atom() => non_neg_integer()}}
        }

  @spec ok_row(Dsxir.Example.t(), Dsxir.Prediction.t(), float()) :: row()
  def ok_row(%Dsxir.Example{} = ex, %Dsxir.Prediction{} = pred, metric)
      when is_float(metric) do
    %{example: ex, prediction: pred, metric: metric, error: nil}
  end

  @spec error_row(Dsxir.Example.t(), Exception.t()) :: row()
  def error_row(%Dsxir.Example{} = ex, %{__exception__: true} = err) do
    %{example: ex, prediction: nil, metric: nil, error: err}
  end

  @spec score_from(list(float())) :: float()
  def score_from([]), do: 0.0

  def score_from(values) when is_list(values) do
    sum = Enum.sum(values)
    avg = sum / length(values)
    Float.round(avg * 100.0, 1)
  end
end
