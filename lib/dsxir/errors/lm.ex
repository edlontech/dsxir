defmodule Dsxir.Errors.LM do
  @moduledoc "LM-class errors: upstream transport, context-window, rate-limit, authentication."
  use Splode.ErrorClass, class: :lm
end

defmodule Dsxir.Errors.LM.RequestFailed do
  @moduledoc "Raised on a non-classified LM provider error (transport, server error, empty response)."
  use Splode.Error, fields: [:model_id, :status, :parent_error], class: :lm

  def message(%{model_id: model_id, status: status, parent_error: parent_error}) do
    "LM #{model_id} request failed status=#{status} reason=#{inspect(parent_error)}"
  end
end

defmodule Dsxir.Errors.LM.ContextWindow do
  @moduledoc "Raised when the LM rejects a request because the prompt exceeded its context window."
  use Splode.Error,
    fields: [:model_id, :prompt_tokens, :limit, :parent_error],
    class: :lm

  def message(%{model_id: model_id, prompt_tokens: prompt_tokens, limit: limit}) do
    base = "Context window exceeded for #{inspect(model_id)}"

    [base, prompt_segment(prompt_tokens), limit_segment(limit)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp prompt_segment(nil), do: nil
  defp prompt_segment(tokens), do: "(prompt tokens: #{tokens})"

  defp limit_segment(nil), do: nil
  defp limit_segment(limit), do: "(limit: #{limit})"
end

defmodule Dsxir.Errors.LM.RateLimited do
  @moduledoc "Raised when the LM rejects a request due to rate limits, with optional retry_after."
  use Splode.Error, fields: [:model_id, :retry_after], class: :lm

  def message(%{model_id: model_id, retry_after: retry_after}) do
    "LM #{model_id} rate-limited retry_after=#{retry_after}"
  end
end

defmodule Dsxir.Errors.LM.Authentication do
  @moduledoc "Raised when the LM rejects a request due to missing or invalid credentials."
  use Splode.Error, fields: [:model_id, :reason], class: :lm

  def message(%{model_id: model_id, reason: reason}) do
    "LM #{model_id} authentication failed: #{inspect(reason)}"
  end
end
