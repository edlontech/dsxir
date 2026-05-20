defmodule Dsxir.Errors.Runtime do
  @moduledoc "Runtime-class errors raised during executor execution."
  use Splode.ErrorClass, class: :runtime
end

defmodule Dsxir.Errors.Runtime.PredicateError do
  @moduledoc "Raised when a guard predicate fails at runtime (type mismatch slipping past static checking, missing field, etc.)."
  use Splode.Error, fields: [:node, :ast, :env, :reason], class: :runtime

  def message(%{node: node, reason: reason}),
    do: "predicate at #{inspect(node)} failed at runtime: #{inspect(reason)}"
end

defmodule Dsxir.Errors.Runtime.SkippedOutputs do
  @moduledoc "Raised by the executor when `on_skip: :raise` (the default) and any program output's chain was skipped."
  use Splode.Error, fields: [:skipped, :prediction], class: :runtime

  def message(%{skipped: skipped}),
    do: "program outputs were skipped: #{inspect(skipped)}; use on_skip: :tagged_tuple to opt out"
end
