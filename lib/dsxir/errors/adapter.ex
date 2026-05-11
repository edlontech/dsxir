defmodule Dsxir.Errors.Adapter do
  @moduledoc "Adapter-class errors: parse, Zoi validation, and fallback exhaustion."
  use Splode.ErrorClass, class: :adapter
end

defmodule Dsxir.Errors.Adapter.ParseError do
  @moduledoc false
  use Splode.Error, fields: [:adapter, :field, :reason, :raw_response], class: :adapter
  @type t :: %__MODULE__{}

  def message(%{adapter: adapter, field: nil, reason: reason}) do
    "#{inspect(adapter)} parse failed reason=#{inspect(reason)}"
  end

  def message(%{adapter: adapter, field: field, reason: reason}) do
    "#{inspect(adapter)} parse failed field=#{inspect(field)} reason=#{inspect(reason)}"
  end
end

defmodule Dsxir.Errors.Adapter.ZoiValidation do
  @moduledoc false
  use Splode.Error, fields: [:adapter, :field, :zoi_errors], class: :adapter
  @type t :: %__MODULE__{}

  def message(%{adapter: adapter, field: field, zoi_errors: zoi_errors}) do
    "#{inspect(adapter)} Zoi validation failed for #{inspect(field)}: #{inspect(zoi_errors)}"
  end
end

defmodule Dsxir.Errors.Adapter.FallbackExhausted do
  @moduledoc false
  use Splode.Error, fields: [:from, :to, :last_error], class: :adapter
  @type t :: %__MODULE__{}

  def message(%{from: from, to: to, last_error: last_error}) do
    last_str =
      if is_exception(last_error), do: Exception.message(last_error), else: inspect(last_error)

    "fallback #{inspect(from)} -> #{inspect(to)} exhausted: #{last_str}"
  end
end
