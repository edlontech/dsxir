defmodule Dsxir.Errors.Adapter do
  @moduledoc "Adapter-class errors: parse, Zoi validation, and fallback exhaustion."
  use Splode.ErrorClass, class: :adapter
end

defmodule Dsxir.Errors.Adapter.ParseError do
  @moduledoc false
  use Splode.Error, fields: [:adapter, :field, :reason, :raw_response], class: :adapter
  @type t :: %__MODULE__{}
  def message(struct), do: inspect(struct)
end

defmodule Dsxir.Errors.Adapter.ZoiValidation do
  @moduledoc false
  use Splode.Error, fields: [:adapter, :field, :zoi_errors], class: :adapter
  @type t :: %__MODULE__{}
  def message(struct), do: inspect(struct)
end

defmodule Dsxir.Errors.Adapter.FallbackExhausted do
  @moduledoc false
  use Splode.Error, fields: [:from, :to, :last_error], class: :adapter
  @type t :: %__MODULE__{}
  def message(struct), do: inspect(struct)
end
