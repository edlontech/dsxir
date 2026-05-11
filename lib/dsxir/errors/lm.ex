defmodule Dsxir.Errors.LM do
  @moduledoc "LM-class errors: upstream transport, context-window, rate-limit, authentication."
  use Splode.ErrorClass, class: :lm
end

defmodule Dsxir.Errors.LM.RequestFailed do
  @moduledoc false
  use Splode.Error, fields: [:model_id, :status, :sycophant_error], class: :lm
  def message(struct), do: inspect(struct)
end

defmodule Dsxir.Errors.LM.ContextWindow do
  @moduledoc false
  use Splode.Error, fields: [:model_id, :prompt_tokens, :limit], class: :lm
  def message(struct), do: inspect(struct)
end

defmodule Dsxir.Errors.LM.RateLimited do
  @moduledoc false
  use Splode.Error, fields: [:model_id, :retry_after], class: :lm
  def message(struct), do: inspect(struct)
end

defmodule Dsxir.Errors.LM.Authentication do
  @moduledoc false
  use Splode.Error, fields: [:model_id, :reason], class: :lm
  def message(struct), do: inspect(struct)
end
