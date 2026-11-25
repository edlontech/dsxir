if Code.ensure_loaded?(ReqLLM) do
  defmodule Dsxir.LM.ReqLLM do
    @moduledoc """
    ReqLLM-backed implementation of the `Dsxir.LM` behaviour.

    Only compiled when the optional `:req_llm` dependency is present.

    Config shape:

        [model: "openai:gpt-4o-mini", api_key: nil | binary,
         base_url: nil | binary, temperature: float, max_tokens: integer,
         embedding_model: nil | binary]

    `:model` accepts any ReqLLM model spec (`"provider:model"` string, tuple,
    `%LLMDB.Model{}` or inline map). Unknown config keys pass through to ReqLLM,
    which validates them against the provider's option schema. Dsxir's own
    settings keys (`:lm`, `:adapter`, `:cache`, `:metadata`, `:hints`, ...) are
    stripped first, since ReqLLM rejects options it does not know.

    Per-call opts override config opts via `Keyword.merge/2`. `api_key` and
    `base_url` are native ReqLLM options and pass through unchanged. The
    `:headers` config key is reserved for future use and intentionally ignored.

    Messages are passed as-is: ReqLLM accepts the `%{role:, content:}` maps the
    Dsxir adapters build, as well as `%ReqLLM.Message{}` structs.

    ## Streaming

    When `:stream` is set, `ReqLLM.stream_text/3` is used and each
    `%ReqLLM.StreamChunk{}` is translated into a `%Dsxir.LM.StreamChunk{}`
    before the sink sees it: `:content` becomes `:text_delta`, `:thinking`
    becomes `:reasoning_delta` and a terminal error meta chunk becomes `:failed`
    with a translated `Dsxir.Errors.LM.*`. After the last chunk, a `:usage`
    chunk and a `:done` chunk are emitted. Tool-call chunks are not forwarded.
    Both the 1-arity sink and the 2-arity `{acc, fun}` accumulator form are
    supported. The final assembled `{:ok, text, usage}` is still returned.

    ## Usage extraction

    ReqLLM's usage map is mapped into a `%Dsxir.Cost{}` with `calls: 1`.
    Token counts go through `ReqLLM.Usage.normalize/1`; costs are read from
    `:input_cost`, `:output_cost`, `:reasoning_cost` and `:total_cost`, and
    `:currency` from `:pricing`. A `nil` usage yields `Dsxir.LM.empty_usage/0`.

    ## Error translation

    `%ReqLLM.Error.API.Request{}` errors are translated by HTTP status:
    401/403 become `Dsxir.Errors.LM.Authentication`, 429 becomes
    `Dsxir.Errors.LM.RateLimited` (with `retry_after` in seconds from the
    `retry-after` header), and a 400 whose reason or body matches a context-window phrase
    becomes `Dsxir.Errors.LM.ContextWindow`. Everything else becomes
    `Dsxir.Errors.LM.RequestFailed` carrying the original error.
    """

    @behaviour Dsxir.LM

    alias Dsxir.LM.StreamChunk
    alias ReqLLM.Error.API.Request, as: ApiRequest

    @context_window_patterns [
      ~r/context length/i,
      ~r/maximum context/i,
      ~r/prompt is too long/i,
      ~r/too many tokens/i,
      ~r/exceeds.*token/i,
      ~r/request is too large/i
    ]

    @dsxir_internal_opts [
      :path,
      :adapter,
      :cache,
      :_dsxir_nonce,
      :_cost_scope,
      :degraded,
      :hint,
      :lm,
      :callbacks,
      :call_plugs,
      :program_plugs,
      :metadata,
      :hints,
      :listen,
      :stream,
      :headers
    ]

    @impl Dsxir.LM
    def generate_text(config, messages, opts) do
      model = Keyword.fetch!(config, :model)
      req_opts = build_opts(config, opts, [:model])

      result =
        case Keyword.get(opts, :stream) do
          nil -> ReqLLM.generate_text(model, messages, req_opts)
          sink -> stream_text(model, messages, req_opts, sink)
        end

      case result do
        {:ok, %ReqLLM.Response{} = response} ->
          case ReqLLM.Response.text(response) do
            text when is_binary(text) ->
              {:ok, text, extract_usage(response.usage)}

            nil ->
              {:error,
               %Dsxir.Errors.LM.RequestFailed{
                 model_id: model,
                 status: nil,
                 parent_error: :empty_response
               }}
          end

        {:error, err} ->
          {:error, translate(err, model)}
      end
    end

    @impl Dsxir.LM
    def generate_object(config, messages, schema, opts) do
      model = Keyword.fetch!(config, :model)
      req_opts = build_opts(config, opts, [:model])

      case ReqLLM.generate_object(model, messages, schema, req_opts) do
        {:ok, %ReqLLM.Response{object: object, usage: usage}} when is_map(object) ->
          {:ok, object, extract_usage(usage)}

        {:ok, %ReqLLM.Response{}} ->
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

    @impl Dsxir.LM
    def embed(config, inputs, opts) do
      model =
        Keyword.get(opts, :embedding_model, Keyword.get(config, :embedding_model)) ||
          Keyword.fetch!(config, :model)

      req_opts =
        config
        |> build_opts(opts, [:model, :embedding_model])
        |> Keyword.put(:return_usage, true)

      case ReqLLM.embed(model, inputs, req_opts) do
        {:ok, %{embedding: vectors, usage: usage}} ->
          {:ok, vectors, extract_usage(usage)}

        {:error, err} ->
          {:error, translate(err, model)}
      end
    end

    defp build_opts(config, opts, config_only_keys) do
      config
      |> Keyword.drop(config_only_keys)
      |> Keyword.merge(opts)
      |> Keyword.drop(@dsxir_internal_opts ++ config_only_keys)
    end

    defp stream_text(model, messages, req_opts, sink) do
      with {:ok, stream_response} <- ReqLLM.stream_text(model, messages, req_opts) do
        stream_response
        |> tap_stream(sink, model)
        |> ReqLLM.StreamResponse.to_response()
      end
    end

    # Feeds translated chunks to the sink while passing the original chunks
    # through untouched, so `ReqLLM.StreamResponse.to_response/1` still
    # assembles the final response. The accumulator form threads `acc` across
    # chunks; the `:usage` and `:done` chunks are emitted once the provider
    # stream is exhausted, unless a `:failed` chunk was already sent.
    defp tap_stream(stream_response, sink, model) do
      {acc, fun} = fold_sink(sink)

      stream =
        Stream.transform(
          stream_response.stream,
          fn -> {acc, false} end,
          fn chunk, {acc, failed?} ->
            case to_chunk(chunk, model) do
              nil -> {[chunk], {acc, failed?}}
              %StreamChunk{type: :failed} = c -> {[chunk], {fun.(c, acc), true}}
              c -> {[chunk], {fun.(c, acc), failed?}}
            end
          end,
          fn
            {acc, true} ->
              {[], {acc, true}}

            {acc, false} ->
              usage = extract_usage(ReqLLM.StreamResponse.usage(stream_response))
              acc = fun.(%StreamChunk{type: :usage, data: usage}, acc)
              {[], {fun.(%StreamChunk{type: :done}, acc), false}}
          end,
          fn _ -> :ok end
        )

      %{stream_response | stream: stream}
    end

    defp fold_sink(fun) when is_function(fun, 1), do: {nil, fn chunk, _ -> fun.(chunk) end}
    defp fold_sink({acc, fun}) when is_function(fun, 2), do: {acc, fun}

    defp to_chunk(%ReqLLM.StreamChunk{type: :content, text: text}, _model) when is_binary(text),
      do: %StreamChunk{type: :text_delta, data: text}

    defp to_chunk(%ReqLLM.StreamChunk{type: :thinking, text: text}, _model) when is_binary(text),
      do: %StreamChunk{type: :reasoning_delta, data: text}

    defp to_chunk(%ReqLLM.StreamChunk{type: :meta, metadata: %{error: error}}, model)
         when not is_nil(error),
         do: %StreamChunk{type: :failed, data: translate(error, model)}

    defp to_chunk(_chunk, _model), do: nil

    defp extract_usage(nil), do: Dsxir.LM.empty_usage()

    defp extract_usage(usage) when is_map(usage) do
      tokens = ReqLLM.Usage.normalize(usage)

      %Dsxir.Cost{
        input_tokens: tokens.input_tokens,
        output_tokens: tokens.output_tokens,
        cache_read_tokens: tokens[:cache_read_tokens],
        cache_write_tokens: tokens[:cache_write_tokens],
        reasoning_tokens: tokens[:reasoning_tokens],
        input_cost: usage[:input_cost],
        output_cost: usage[:output_cost],
        reasoning_cost: usage[:reasoning_cost],
        total_cost: usage[:total_cost],
        currency: currency(usage[:pricing]),
        calls: 1
      }
    end

    defp currency(%{currency: currency}), do: currency
    defp currency(_), do: nil

    defp translate(%ApiRequest{status: status} = err, model) when status in [401, 403] do
      %Dsxir.Errors.LM.Authentication{model_id: model, reason: err}
    end

    defp translate(%ApiRequest{status: 429, headers: headers}, model) do
      %Dsxir.Errors.LM.RateLimited{model_id: model, retry_after: retry_after(headers)}
    end

    defp translate(%ApiRequest{status: 400} = err, model) do
      text = "#{err.reason} #{body_text(err.response_body)}"

      if Enum.any?(@context_window_patterns, &Regex.match?(&1, text)) do
        %Dsxir.Errors.LM.ContextWindow{
          model_id: model,
          prompt_tokens: extract_int(text, ~r/(\d+)\s+tokens/i),
          limit: extract_int(text, ~r/limit\s+of\s+(\d+)/i),
          parent_error: err
        }
      else
        %Dsxir.Errors.LM.RequestFailed{model_id: model, status: 400, parent_error: err}
      end
    end

    defp translate(%ApiRequest{status: status} = err, model) do
      %Dsxir.Errors.LM.RequestFailed{model_id: model, status: status, parent_error: err}
    end

    defp translate(other, model) do
      %Dsxir.Errors.LM.RequestFailed{model_id: model, status: nil, parent_error: other}
    end

    defp retry_after(nil), do: nil

    defp retry_after(headers) do
      case Req.Response.get_retry_after(Req.Response.new(headers: headers)) do
        nil -> nil
        ms -> div(ms, 1000)
      end
    end

    defp body_text(body) when is_binary(body), do: body
    defp body_text(nil), do: ""
    defp body_text(body), do: inspect(body)

    defp extract_int(text, regex) do
      case Regex.run(regex, text, capture: :all_but_first) do
        [int_str] -> String.to_integer(int_str)
        _ -> nil
      end
    end
  end
end
