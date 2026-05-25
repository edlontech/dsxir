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

defmodule Dsxir.Errors.Framework.MissingInput do
  @moduledoc """
  Framework-invariant breach. If validation succeeded, this cannot fire.
  Never user-facing; if you see this, file a bug.
  """
  use Splode.Error, fields: [:node, :field], class: :framework

  def message(%{node: node, field: field}),
    do: "framework bug: missing input #{inspect(field)} for node #{inspect(node)}"
end

defmodule Dsxir.Errors.Framework.CycleDetected do
  @moduledoc """
  Raised by the executor when topological sort detects a cycle. The
  validator already proves runtime programs are acyclic, so this surfaces
  a framework-invariant breach (someone bypassed the validator).
  """
  use Splode.Error, fields: [:nodes], class: :framework

  def message(%{nodes: nodes}),
    do: "framework bug: cycle detected among nodes #{inspect(nodes)}"
end

defmodule Dsxir.Errors.Framework.UndefinedFunction do
  @moduledoc """
  Raised when a worker exits with `:undef` — typically the metric or program
  module was not loaded in the `Task.Supervisor` worker (a common LiveBook
  pitfall where the metric cell was not evaluated before the eval cell).
  """
  use Splode.Error, fields: [:module, :function, :arity], class: :framework

  def message(%{module: module, function: function, arity: arity}) do
    "undefined function #{inspect(module)}.#{function}/#{arity} (module not loaded in worker?)"
  end
end

defmodule Dsxir.Errors.Framework.GEPAOperatorFailed do
  @moduledoc "Raised when a GEPA reflective operator fails to produce a valid offspring."
  use Splode.Error,
    fields: [:operator, :parents, :reason, :parent_error],
    class: :framework

  def message(%{operator: op, reason: r}),
    do: "GEPA operator #{inspect(op)} failed: #{inspect(r)}"
end
