defmodule Dsxir.Errors.Unknown do
  @moduledoc "Unknown-class errors: Splode fallback when an error cannot be classified."
  use Splode.ErrorClass, class: :unknown
end

defmodule Dsxir.Errors.Unknown.Unknown do
  @moduledoc false
  use Splode.Error, fields: [:error], class: :unknown

  def message(%{error: error}) do
    "unknown error: #{inspect(error)}"
  end
end
