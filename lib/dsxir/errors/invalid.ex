defmodule Dsxir.Errors.Invalid do
  @moduledoc "Invalid-class errors: configuration, signature, and trainset shape problems."
  use Splode.ErrorClass, class: :invalid
end

defmodule Dsxir.Errors.Invalid.Configuration do
  @moduledoc "Raised when `Dsxir.configure/1` or runtime settings receive an unknown or malformed key."
  use Splode.Error, fields: [:key, :value, :reason], class: :invalid

  def message(%{key: key, value: value, reason: reason}) do
    "invalid configuration: key=#{inspect(key)} value=#{inspect(value)} reason=#{inspect(reason)}"
  end
end

defmodule Dsxir.Errors.Invalid.Signature do
  @moduledoc "Raised when a signature declaration is malformed at compile time."
  use Splode.Error, fields: [:module, :field, :reason], class: :invalid

  def message(%{module: module, field: field, reason: reason}) do
    "invalid signature in #{inspect(module)}: field=#{inspect(field)} reason=#{inspect(reason)}"
  end
end

defmodule Dsxir.Errors.Invalid.Module do
  @moduledoc "Raised when a `Dsxir.Module` predicate dispatches to an undeclared predictor name."
  use Splode.Error, fields: [:module, :predictor, :reason], class: :invalid

  def message(%{module: module, predictor: predictor, reason: reason}) do
    "invalid module #{inspect(module)}: predictor=#{inspect(predictor)} reason=#{inspect(reason)}"
  end
end

defmodule Dsxir.Errors.Invalid.SignatureMismatch do
  @moduledoc "Raised when a saved artifact hydrates into a module whose signature shape does not match."
  use Splode.Error, fields: [:module, :expected, :loaded, :diff], class: :invalid

  def message(%{module: module, diff: diff}) do
    "signature mismatch on hydrate into #{inspect(module)}: diff=#{inspect(diff)}"
  end
end

defmodule Dsxir.Errors.Invalid.Trainset do
  @moduledoc "Raised when an optimizer is invoked with an empty or malformed trainset."
  use Splode.Error, fields: [:reason, :example], class: :invalid

  def message(%{reason: reason}) do
    "invalid trainset: reason=#{inspect(reason)}"
  end
end

defmodule Dsxir.Errors.Invalid.Metric do
  @moduledoc "Raised when a metric returns a non-numeric/non-boolean value for an example."
  use Splode.Error, fields: [:example, :returned, :expected], class: :invalid

  def message(%{example: example, returned: returned, expected: expected}) do
    "invalid metric output for example=#{inspect(example)}: returned=#{inspect(returned)} expected=#{inspect(expected)}"
  end
end

defmodule Dsxir.Errors.Invalid.Tool do
  @moduledoc "Raised when a `Dsxir.Primitives.Tool` declaration or call is malformed."
  use Splode.Error, fields: [:tool, :reason, :inner], class: :invalid

  @type t :: %__MODULE__{}

  def message(%{tool: tool, reason: reason, inner: inner}) do
    "invalid tool: tool=#{inspect(tool)} reason=#{inspect(reason)} inner=#{inspect(inner)}"
  end
end

defmodule Dsxir.Errors.Invalid.NotCheckpointable do
  @moduledoc "Raised when `OptimizerSession.start_link/2` is called with an optimizer that does not implement the checkpointing callbacks."
  use Splode.Error, fields: [:optimizer, :missing], class: :invalid

  @type t :: %__MODULE__{optimizer: module(), missing: [atom()]}

  def message(%{optimizer: opt, missing: missing}) do
    "optimizer #{inspect(opt)} is not checkpointable; missing callbacks: #{inspect(missing)}. " <>
      "Use Dsxir.Optimizer.compile/5 for synchronous one-shot runs."
  end
end

defmodule Dsxir.Errors.Invalid.AlreadyTerminal do
  @moduledoc "Raised when an OptimizerSession operation targets a session that is already in a terminal state."
  use Splode.Error, fields: [:session_id, :status], class: :invalid

  @type t :: %__MODULE__{session_id: String.t(), status: atom()}

  def message(%{session_id: id, status: status}) do
    "session #{inspect(id)} is in terminal status #{inspect(status)}; cannot resume or signal"
  end
end

defmodule Dsxir.Errors.Invalid.ResumeMismatch do
  @moduledoc "Raised when a checkpoint cannot be resumed because optimizer, sampler version, or trainset hash disagree."
  use Splode.Error, fields: [:session_id, :reason, :expected, :got], class: :invalid

  @type t :: %__MODULE__{session_id: String.t(), reason: atom(), expected: term(), got: term()}

  def message(%{session_id: id, reason: reason, expected: e, got: g}) do
    "resume mismatch for session #{inspect(id)}: reason=#{inspect(reason)} expected=#{inspect(e)} got=#{inspect(g)}"
  end
end
