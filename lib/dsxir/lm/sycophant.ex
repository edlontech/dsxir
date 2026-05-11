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
  """

  @behaviour Dsxir.LM

  alias Sycophant.Error.Invalid, as: SycInvalid
  alias Sycophant.Error.Provider, as: SycProvider

  @impl Dsxir.LM
  def generate_text(config, messages, opts) do
    model = Keyword.fetch!(config, :model)
    merged = Keyword.merge(Keyword.delete(config, :model), opts)

    sycophant_opts =
      merged
      |> Keyword.drop([:api_key, :base_url, :headers])
      |> maybe_put_credentials(merged)

    case Sycophant.generate_text(model, messages, sycophant_opts) do
      {:ok, %Sycophant.Response{text: text}} when is_binary(text) ->
        {:ok, text}

      {:ok, %Sycophant.Response{text: nil}} ->
        {:error,
         %Dsxir.Errors.LM.RequestFailed{
           model_id: model,
           status: nil,
           sycophant_error: :empty_response
         }}

      {:error, err} ->
        {:error, translate(err, model)}
    end
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
    %Dsxir.Errors.LM.RequestFailed{model_id: model, status: status, sycophant_error: err}
  end

  defp translate(%SycProvider.BadRequest{status: status} = err, model) do
    %Dsxir.Errors.LM.RequestFailed{model_id: model, status: status, sycophant_error: err}
  end

  defp translate(%SycProvider.Timeout{} = err, model) do
    %Dsxir.Errors.LM.RequestFailed{model_id: model, status: nil, sycophant_error: err}
  end

  defp translate(%SycProvider.ResponseInvalid{} = err, model) do
    %Dsxir.Errors.LM.RequestFailed{model_id: model, status: nil, sycophant_error: err}
  end

  defp translate(%SycProvider.ContentFiltered{} = err, model) do
    %Dsxir.Errors.LM.RequestFailed{model_id: model, status: nil, sycophant_error: err}
  end

  defp translate(%SycProvider.ModelNotFound{} = err, model) do
    %Dsxir.Errors.LM.RequestFailed{model_id: model, status: nil, sycophant_error: err}
  end

  defp translate(other, model) do
    %Dsxir.Errors.LM.RequestFailed{model_id: model, status: nil, sycophant_error: other}
  end
end
