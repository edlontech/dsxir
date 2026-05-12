defmodule Dsxir.LM.Sycophant do
  @moduledoc """
  Sycophant-backed implementation of the `Dsxir.LM` behaviour.

  Config shape: `[model: "openai:gpt-4o-mini", api_key: nil | binary,
  base_url: nil | binary, temperature: float, max_tokens: integer,
  top_p: float, num_retries: integer]`. Unknown config keys pass through to
  Sycophant; Sycophant validates them against the resolved wire protocol's
  param schema.

  Per-call opts override per-config opts via `Keyword.merge/2`. `api_key` and
  `base_url` are lifted into `credentials: %{...}` for Sycophant. The `:headers`
  config key is reserved for future use and intentionally ignored.

  ## Streaming

  The `:stream` opt is forwarded to `Sycophant.generate_text/3` unchanged.
  Sycophant invokes the 1-arity callback with `%Sycophant.StreamChunk{}` values
  (`:text_delta`, `:tool_call_delta`, `:reasoning_delta`, `:usage`, `:failed`,
  `:incomplete`, `:cancelled`, `:done`) as the response streams in; the final
  assembled `{:ok, text, usage}` tuple is still returned by this callback so
  `Dsxir.Predictor.Predict` can build its `%Dsxir.Prediction{}` normally.

  ## Usage extraction

  On a successful response, the `%Sycophant.Usage{}` struct is flattened into
  the `Dsxir.LM` usage map. When Sycophant reports `nil` usage, the empty
  usage map (`tokens_in: nil`, `tokens_out: nil`, `cost: nil`) is returned so
  downstream telemetry can rely on the keys always being present.

  | `Dsxir.LM` usage key | `Sycophant.Usage` field |
  | -------------------- | ----------------------- |
  | `:tokens_in`         | `:input_tokens`         |
  | `:tokens_out`        | `:output_tokens`        |
  | `:cost`              | `:total_cost`           |

  ## Error translation

  Provider errors are translated into typed `Dsxir.Errors.LM.*` structs. A
  `%Sycophant.Error.Provider.BadRequest{status: 400}` is classified against a
  small set of regexes (case-insensitive) on its `:body` to detect upstream
  context-window-exceeded responses:

    * `~r/context length/i`
    * `~r/maximum context/i`
    * `~r/prompt is too long/i`
    * `~r/too many tokens/i`
    * `~r/exceeds.*token/i`
    * `~r/request is too large/i`

  When any of those match the body, the error becomes a
  `Dsxir.Errors.LM.ContextWindow` (with `prompt_tokens`/`limit` extracted when
  the body carries them). All other BadRequest bodies stay as
  `Dsxir.Errors.LM.RequestFailed{status: 400}`.
  """

  @behaviour Dsxir.LM

  alias Sycophant.Error.Invalid, as: SycInvalid
  alias Sycophant.Error.Provider, as: SycProvider

  @context_window_patterns [
    ~r/context length/i,
    ~r/maximum context/i,
    ~r/prompt is too long/i,
    ~r/too many tokens/i,
    ~r/exceeds.*token/i,
    ~r/request is too large/i
  ]

  @impl Dsxir.LM
  def generate_text(config, messages, opts) do
    model = Keyword.fetch!(config, :model)
    sycophant_opts = build_sycophant_opts(config, opts)

    case Sycophant.generate_text(model, messages, sycophant_opts) do
      {:ok, %Sycophant.Response{text: text, usage: usage}} when is_binary(text) ->
        {:ok, text, extract_usage(usage)}

      {:ok, %Sycophant.Response{text: nil}} ->
        {:error,
         %Dsxir.Errors.LM.RequestFailed{
           model_id: model,
           status: nil,
           parent_error: :empty_response
         }}

      {:error, err} ->
        {:error, translate(err, model)}
    end
  end

  @impl Dsxir.LM
  def generate_object(config, messages, schema, opts) do
    model = Keyword.fetch!(config, :model)
    sycophant_opts = build_sycophant_opts(config, opts)

    case Sycophant.generate_object(model, messages, schema, sycophant_opts) do
      {:ok, %Sycophant.Response{object: object, usage: usage}} when is_map(object) ->
        {:ok, object, extract_usage(usage)}

      {:ok, %Sycophant.Response{object: nil}} ->
        {:error,
         %Dsxir.Errors.LM.RequestFailed{
           model_id: model,
           status: nil,
           parent_error: :empty_object
         }}

      {:error, err} ->
        {:error, translate(err, model)}
    end
  end

  @dsxir_internal_opts [:path, :adapter]
  @credential_opts [:api_key, :base_url, :headers]

  defp build_sycophant_opts(config, opts) do
    merged = Keyword.merge(Keyword.delete(config, :model), opts)

    merged
    |> Keyword.drop(@credential_opts ++ @dsxir_internal_opts)
    |> maybe_put_credentials(merged)
  end

  defp extract_usage(nil), do: Dsxir.LM.empty_usage()

  defp extract_usage(%Sycophant.Usage{} = u) do
    %{tokens_in: u.input_tokens, tokens_out: u.output_tokens, cost: u.total_cost}
  end

  defp maybe_put_credentials(opts, source) do
    creds =
      %{}
      |> put_if(:api_key, Keyword.get(source, :api_key))
      |> put_if(:base_url, Keyword.get(source, :base_url))

    if map_size(creds) == 0, do: opts, else: Keyword.put(opts, :credentials, creds)
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  defp translate(%SycProvider.AuthenticationFailed{} = err, model) do
    %Dsxir.Errors.LM.Authentication{model_id: model, reason: err}
  end

  defp translate(%SycProvider.RateLimited{retry_after: ra}, model) do
    %Dsxir.Errors.LM.RateLimited{model_id: model, retry_after: ra}
  end

  defp translate(%SycInvalid.MissingCredentials{}, model) do
    %Dsxir.Errors.LM.Authentication{model_id: model, reason: :missing_credentials}
  end

  defp translate(%SycProvider.ServerError{status: status} = err, model) do
    %Dsxir.Errors.LM.RequestFailed{model_id: model, status: status, parent_error: err}
  end

  defp translate(%SycProvider.BadRequest{status: 400, body: body} = err, model)
       when is_binary(body) do
    if context_window_phrase?(body) do
      %Dsxir.Errors.LM.ContextWindow{
        model_id: model,
        prompt_tokens: extract_int(body, ~r/(\d+)\s+tokens/i),
        limit: extract_int(body, ~r/limit\s+of\s+(\d+)/i),
        parent_error: err
      }
    else
      %Dsxir.Errors.LM.RequestFailed{model_id: model, status: 400, parent_error: err}
    end
  end

  defp translate(%SycProvider.BadRequest{status: status} = err, model) do
    %Dsxir.Errors.LM.RequestFailed{model_id: model, status: status, parent_error: err}
  end

  defp translate(%SycProvider.Timeout{} = err, model) do
    %Dsxir.Errors.LM.RequestFailed{model_id: model, status: nil, parent_error: err}
  end

  defp translate(%SycProvider.ResponseInvalid{} = err, model) do
    %Dsxir.Errors.LM.RequestFailed{model_id: model, status: nil, parent_error: err}
  end

  defp translate(%SycProvider.ContentFiltered{} = err, model) do
    %Dsxir.Errors.LM.RequestFailed{model_id: model, status: nil, parent_error: err}
  end

  defp translate(%SycProvider.ModelNotFound{} = err, model) do
    %Dsxir.Errors.LM.RequestFailed{model_id: model, status: nil, parent_error: err}
  end

  defp translate(other, model) do
    %Dsxir.Errors.LM.RequestFailed{model_id: model, status: nil, parent_error: other}
  end

  defp context_window_phrase?(body) do
    Enum.any?(@context_window_patterns, &Regex.match?(&1, body))
  end

  defp extract_int(body, regex) do
    case Regex.run(regex, body, capture: :all_but_first) do
      [int_str] ->
        case Integer.parse(int_str) do
          {n, _} -> n
          :error -> nil
        end

      _ ->
        nil
    end
  end
end
