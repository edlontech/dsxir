defmodule Dsxir.Errors.Invalid do
  @moduledoc "Invalid-class errors: configuration, signature, and trainset shape problems."
  use Splode.ErrorClass, class: :invalid
end

defmodule Dsxir.Errors.Invalid.Configuration do
  @moduledoc false
  use Splode.Error, fields: [:key, :value, :reason], class: :invalid

  def message(%{key: key, value: value, reason: reason}) do
    "invalid configuration: key=#{inspect(key)} value=#{inspect(value)} reason=#{inspect(reason)}"
  end
end

defmodule Dsxir.Errors.Invalid.Signature do
  @moduledoc false
  use Splode.Error, fields: [:module, :field, :reason], class: :invalid

  def message(%{module: module, field: field, reason: reason}) do
    "invalid signature in #{inspect(module)}: field=#{inspect(field)} reason=#{inspect(reason)}"
  end
end

defmodule Dsxir.Errors.Invalid.Module do
  @moduledoc false
  use Splode.Error, fields: [:module, :predictor, :reason], class: :invalid

  def message(%{module: module, predictor: predictor, reason: reason}) do
    "invalid module #{inspect(module)}: predictor=#{inspect(predictor)} reason=#{inspect(reason)}"
  end
end

defmodule Dsxir.Errors.Invalid.SignatureMismatch do
  @moduledoc false
  use Splode.Error, fields: [:module, :expected, :loaded, :diff], class: :invalid

  def message(%{module: module, diff: diff}) do
    "signature mismatch on hydrate into #{inspect(module)}: diff=#{inspect(diff)}"
  end
end

defmodule Dsxir.Errors.Invalid.Trainset do
  @moduledoc false
  use Splode.Error, fields: [:reason, :example], class: :invalid

  def message(%{reason: reason}) do
    "invalid trainset: reason=#{inspect(reason)}"
  end
end

defmodule Dsxir.Errors.Invalid.Metric do
  @moduledoc false
  use Splode.Error, fields: [:example, :returned, :expected], class: :invalid

  def message(%{example: example, returned: returned, expected: expected}) do
    "invalid metric output for example=#{inspect(example)}: returned=#{inspect(returned)} expected=#{inspect(expected)}"
  end
end
