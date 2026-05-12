defmodule Dsxir.Errors.Framework do
  @moduledoc "Framework-class errors: dsxir internal bugs surfaced as typed errors."
  use Splode.ErrorClass, class: :framework
end

defmodule Dsxir.Errors.Framework.PredictorError do
  @moduledoc "Raised when an internal predictor invariant fails (timeout, trajectory overshoot, etc.)."
  use Splode.Error,
    fields: [:predictor, :signature, :inner, :reason, :trajectory],
    class: :framework

  def message(%{predictor: predictor, signature: signature, inner: inner, reason: reason}) do
    "framework predictor error: predictor=#{inspect(predictor)} signature=#{inspect(signature)} inner=#{inspect(inner)} reason=#{inspect(reason)}"
  end
end

defmodule Dsxir.Errors.Framework.OptimizerError do
  @moduledoc "Raised when an optimizer aggregates more per-example errors than `:max_errors` allows."
  use Splode.Error, fields: [:optimizer, :inner], class: :framework

  def message(%{optimizer: optimizer, inner: inner}) do
    "framework optimizer error: optimizer=#{inspect(optimizer)} inner=#{inspect(inner)}"
  end
end
