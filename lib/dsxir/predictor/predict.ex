defmodule Dsxir.Predictor.Predict do
  @moduledoc """
  Atomic predictor: format with the configured adapter, dispatch through the
  LM, parse, validate, wrap in a `%Dsxir.Prediction{}`.

  Telemetry spans:

    * `[:dsxir, :predictor, :start]` — meta `%{predictor, signature, adapter, **metadata}`.
    * `[:dsxir, :predictor, :stop]`  — meas `%{duration, tokens_in, tokens_out, cache_read_tokens, cache_write_tokens, reasoning_tokens, cost}`, meta `%{predictor, signature, adapter, prediction, error_class: nil, cost: %Dsxir.Cost{}, _cost_scope: [...], **metadata}`.
    * `[:dsxir, :predictor, :exception]` — meas `%{duration}`, meta `%{kind, reason, stacktrace, error_class, **metadata}`.

  Token measurements and `cost` metadata are always present on the stop event;
  token values are `nil` when the upstream LM did not report usage. `cost` is a
  `%Dsxir.Cost{}` struct; `_cost_scope` is `[]` outside a `Dsxir.Cost.track/1`
  block.

  ## Adapter fallback

  When the configured adapter is `Dsxir.Adapter.Chat` and the primary call
  fails with an adapter-class error (`ParseError`, `ZoiValidation`) or an
  `Dsxir.Errors.LM.ContextWindow`, the predictor retries exactly once via
  `Dsxir.Adapter.Json`. Other LM-class errors (`Authentication`,
  `RateLimited`, `RequestFailed`) propagate without retry. If the configured
  adapter is not `Dsxir.Adapter.Chat`, no fallback is attempted.

  Each retry emits `[:dsxir, :adapter, :fallback]` *before* dispatching the
  second call so subscribers see the intent even if the retry also fails. A
  second class-matched failure raises
  `Dsxir.Errors.Adapter.FallbackExhausted`.

  `FallbackExhausted` can surface from two sources: the Chat→Json fallback
  (handled here, distinguished by `from: Dsxir.Adapter.Chat, to:
  Dsxir.Adapter.Json`) and the Json→Json schema retry (handled internally by
  `Dsxir.Adapter.Json`, distinguished by `from: Dsxir.Adapter.Json, to:
  Dsxir.Adapter.Json`). The rescue list catches both.

  ## Recognised opts

    * `:adapter` — override the adapter module for this call. Defaults to
      `Settings.resolve(:adapter)` or `Dsxir.Adapter.Chat`.
    * `:path` — list of path segments stamped onto raised adapter errors for
      nested predictor composition.
    * `:stream` — 1-arity sink `(%Dsxir.Stream.Event{} -> term)` invoked for each
      streamed event (`:token`, `:reasoning`, `:tool_call`, `:usage`, `:done`,
      `:error`). The final `%Dsxir.Prediction{}` is still returned. Chat adapter
      only — the Json adapter raises `Dsxir.Errors.Invalid.Configuration` when
      `:stream` is set.
    * `:listen` — list of string-typed output field names. When set (alongside
      `:stream`), the sink also receives `%Dsxir.Stream.Event{type: :field_delta}`
      events carrying each listened field's marker-stripped tokens as they stream.
      Raises `Dsxir.Errors.Invalid.Configuration` for an unknown or non-string
      field.
  """

  @behaviour Dsxir.Predictor

  alias Dsxir.Prediction
  alias Dsxir.Settings
  alias Dsxir.Telemetry

  @impl Dsxir.Predictor
  def forward(%Dsxir.Program.State{} = state, signature, inputs, opts) do
    adapter = Keyword.get(opts, :adapter, Settings.resolve(:adapter) || Dsxir.Adapter.Chat)
    base_metadata = Settings.resolve(:metadata, %{})

    span_metadata =
      Map.merge(base_metadata, %{
        predictor: __MODULE__,
        signature: signature,
        adapter: adapter
      })

    start_time = System.monotonic_time()

    Telemetry.emit(
      Telemetry.predictor_start(),
      %{system_time: System.system_time()},
      span_metadata
    )

    try do
      case run_adapter(state, signature, inputs, adapter, opts) do
        {:ok, fields, usage, payload} ->
          prediction = build_prediction(fields, payload, usage)
          emit_stop(span_metadata, prediction, usage, start_time)
          {state, prediction}

        {:fallback, primary_err} when adapter == Dsxir.Adapter.Chat ->
          Telemetry.emit(
            Telemetry.adapter_fallback(),
            %{system_time: System.system_time()},
            Map.merge(span_metadata, %{
              from: adapter,
              to: Dsxir.Adapter.Json,
              reason: primary_err
            })
          )

          case run_adapter(state, signature, inputs, Dsxir.Adapter.Json, opts) do
            {:ok, fields, usage, payload} ->
              prediction = build_prediction(fields, payload, usage)

              emit_stop(
                Map.put(span_metadata, :fallback_from, adapter),
                prediction,
                usage,
                start_time
              )

              {state, prediction}

            {:fallback, secondary_err} ->
              raise %Dsxir.Errors.Adapter.FallbackExhausted{
                from: adapter,
                to: Dsxir.Adapter.Json,
                last_error: secondary_err
              }
          end

        {:fallback, err} ->
          raise err
      end
    rescue
      e in [
        Dsxir.Errors.Adapter.ParseError,
        Dsxir.Errors.Adapter.ZoiValidation,
        Dsxir.Errors.Adapter.FallbackExhausted,
        Dsxir.Errors.LM.RequestFailed,
        Dsxir.Errors.LM.Authentication,
        Dsxir.Errors.LM.RateLimited,
        Dsxir.Errors.LM.ContextWindow,
        Dsxir.Errors.Invalid.Configuration
      ] ->
        stamped = stamp_path(e, Keyword.get(opts, :path, []))
        emit_exception(span_metadata, stamped, start_time, __STACKTRACE__)
        reraise stamped, __STACKTRACE__
    end
  end

  defp run_adapter(state, signature, inputs, adapter, opts) do
    opts2 = Keyword.put(opts, :instruction_override, state.instructions_override)

    case adapter_lm_mode(adapter) do
      :object -> adapter.format_and_call(signature, inputs, state.demos, opts2)
      _ -> run_text_adapter(state, signature, inputs, adapter, opts2)
    end
  end

  defp run_text_adapter(state, signature, inputs, adapter, opts) do
    messages = adapter.format(signature, inputs, state.demos, opts)

    lm_opts =
      opts
      |> Keyword.delete(:instruction_override)
      |> wrap_stream_sink(signature)

    case Dsxir.LM.generate_text(messages, lm_opts) do
      {:ok, payload, usage} -> parse_text_response(adapter, signature, payload, usage, opts)
      {:error, %Dsxir.Errors.LM.ContextWindow{} = err} -> {:fallback, err}
      {:error, err} -> raise err
    end
  end

  defp parse_text_response(adapter, signature, payload, usage, opts) do
    case adapter.parse(signature, payload, opts) do
      {:ok, fields} -> {:ok, fields, usage, payload}
      {:error, %{class: :adapter} = err} -> {:fallback, err}
      {:error, err} -> raise err
    end
  end

  # The consumer's `:stream` sink expects `Dsxir.Stream.Event` values. Replace it
  # with an LM-facing callback that translates each `Dsxir.LM.StreamChunk` into an
  # event before the consumer sees it, so the provider chunk type never leaks past
  # this layer. When `:listen` names output fields, the callback also feeds text
  # deltas through a `Dsxir.Adapter.Chat.StreamParser` (the accumulator) and emits
  # `:field_delta` events.
  defp wrap_stream_sink(opts, signature) do
    sink = Keyword.get(opts, :stream)
    listen = Keyword.get(opts, :listen, [])
    opts = Keyword.delete(opts, :listen)

    cond do
      not is_function(sink, 1) ->
        opts

      listen == [] ->
        Keyword.put(opts, :stream, fn chunk ->
          sink.(chunk_to_event(chunk))
          :ok
        end)

      true ->
        Dsxir.Adapter.Chat.validate_listeners!(signature, listen)
        parser = Dsxir.Adapter.Chat.StreamParser.new(listen)
        Keyword.put(opts, :stream, {parser, &stream_reducer(&1, &2, sink)})
    end
  end

  defp stream_reducer(%Dsxir.LM.StreamChunk{type: :text_delta, data: text} = chunk, parser, sink) do
    sink.(chunk_to_event(chunk))
    {events, parser} = Dsxir.Adapter.Chat.StreamParser.push(parser, text)
    Enum.each(events, sink)
    parser
  end

  defp stream_reducer(%Dsxir.LM.StreamChunk{type: :done} = chunk, parser, sink) do
    {events, parser} = Dsxir.Adapter.Chat.StreamParser.finish(parser)
    Enum.each(events, sink)
    sink.(chunk_to_event(chunk))
    parser
  end

  defp stream_reducer(%Dsxir.LM.StreamChunk{} = chunk, parser, sink) do
    sink.(chunk_to_event(chunk))
    parser
  end

  defp chunk_to_event(%Dsxir.LM.StreamChunk{type: :text_delta, data: data}),
    do: %Dsxir.Stream.Event{type: :token, data: data}

  defp chunk_to_event(%Dsxir.LM.StreamChunk{type: :reasoning_delta, data: data}),
    do: %Dsxir.Stream.Event{type: :reasoning, data: data}

  defp chunk_to_event(%Dsxir.LM.StreamChunk{type: :tool_call_delta, data: data}),
    do: %Dsxir.Stream.Event{type: :tool_call, data: data}

  defp chunk_to_event(%Dsxir.LM.StreamChunk{type: :usage, data: data}),
    do: %Dsxir.Stream.Event{type: :usage, data: data}

  defp chunk_to_event(%Dsxir.LM.StreamChunk{type: :done, data: data}),
    do: %Dsxir.Stream.Event{type: :done, data: data}

  defp chunk_to_event(%Dsxir.LM.StreamChunk{type: type, data: data})
       when type in [:failed, :incomplete, :cancelled],
       do: %Dsxir.Stream.Event{type: :error, data: data}

  defp adapter_lm_mode(adapter) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :lm_mode, 0),
      do: adapter.lm_mode(),
      else: :text
  end

  defp build_prediction(fields, payload, usage) do
    Prediction.new(fields,
      completions: completions_for(payload),
      lm_usage: usage
    )
  end

  defp completions_for(payload) when is_binary(payload), do: [payload]
  defp completions_for(_), do: []

  defp emit_stop(span_metadata, prediction, %Dsxir.Cost{} = cost, start_time) do
    duration = System.monotonic_time() - start_time

    Telemetry.emit(
      Telemetry.predictor_stop(),
      Map.put(Dsxir.Cost.to_measurements(cost), :duration, duration),
      Map.merge(span_metadata, %{
        prediction: prediction,
        error_class: nil,
        cost: cost,
        _cost_scope: Settings.resolve(:_cost_scope, [])
      })
    )
  end

  defp stamp_path(err, []), do: err

  defp stamp_path(%{path: existing} = err, parent_path) when is_list(existing) do
    %{err | path: parent_path ++ existing}
  end

  defp emit_exception(span_metadata, err, start_time, stacktrace) do
    duration = System.monotonic_time() - start_time
    class = Map.get(err, :class, :unknown)

    Telemetry.emit(
      Telemetry.predictor_exception(),
      %{duration: duration},
      Map.merge(span_metadata, %{
        kind: :error,
        reason: err,
        stacktrace: stacktrace,
        error_class: class
      })
    )
  end
end
