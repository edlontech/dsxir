defmodule Dsxir.Errors.Framework do
  @moduledoc "Framework-class errors: dsxir internal bugs surfaced as typed errors."
  use Splode.ErrorClass, class: :framework
end

defmodule Dsxir.Errors.Framework.PredictorError do
  @moduledoc false
  use Splode.Error, fields: [:predictor, :signature, :inner], class: :framework
  def message(struct), do: inspect(struct)
end

defmodule Dsxir.Errors.Framework.OptimizerError do
  @moduledoc false
  use Splode.Error, fields: [:optimizer, :inner], class: :framework
  def message(struct), do: inspect(struct)
end
