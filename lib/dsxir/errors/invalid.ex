defmodule Dsxir.Errors.Invalid do
  @moduledoc "Invalid-class errors: configuration, signature, and trainset shape problems."
  use Splode.ErrorClass, class: :invalid
end

defmodule Dsxir.Errors.Invalid.Configuration do
  @moduledoc false
  use Splode.Error, fields: [:key, :value, :reason], class: :invalid
  def message(struct), do: inspect(struct)
end

defmodule Dsxir.Errors.Invalid.Signature do
  @moduledoc false
  use Splode.Error, fields: [:module, :field, :reason], class: :invalid
  def message(struct), do: inspect(struct)
end

defmodule Dsxir.Errors.Invalid.Module do
  @moduledoc false
  use Splode.Error, fields: [:module, :predictor, :reason], class: :invalid
  def message(struct), do: inspect(struct)
end

defmodule Dsxir.Errors.Invalid.SignatureMismatch do
  @moduledoc false
  use Splode.Error, fields: [:module, :expected, :loaded, :diff], class: :invalid
  def message(struct), do: inspect(struct)
end

defmodule Dsxir.Errors.Invalid.Trainset do
  @moduledoc false
  use Splode.Error, fields: [:reason, :example], class: :invalid
  def message(struct), do: inspect(struct)
end

defmodule Dsxir.Errors.Invalid.Metric do
  @moduledoc false
  use Splode.Error, fields: [:example, :returned, :expected], class: :invalid
  def message(struct), do: inspect(struct)
end
