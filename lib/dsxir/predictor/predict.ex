defmodule Dsxir.Predictor.Predict do
  @moduledoc """
  Atomic predictor: format with the configured adapter, dispatch through the
  LM, parse, validate, wrap in a `%Dsxir.Prediction{}`.

  Telemetry spans:

    * `[:dsxir, :predictor, :start]` — meta `%{predictor, signature, adapter, **metadata}`.
    * `[:dsxir, :predictor, :stop]`  — meas `%{duration}`, meta `%{predictor, signature, adapter, prediction, error_class: nil, **metadata}`.
    * `[:dsxir, :predictor, :exception]` — meas `%{duration}`, meta `%{kind, reason, stacktrace, error_class, **metadata}`.

  Token measurements are not yet relayed.
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
      messages = adapter.format(signature, inputs, state.demos, opts)

      case Dsxir.LM.generate_text(messages, opts) do
        {:ok, raw} ->
          case adapter.parse(signature, raw, opts) do
            {:ok, fields} ->
              prediction = Prediction.new(fields, completions: [raw])
              duration = System.monotonic_time() - start_time

              Telemetry.emit(
                Telemetry.predictor_stop(),
                %{duration: duration},
                Map.merge(span_metadata, %{prediction: prediction, error_class: nil})
              )

              {state, prediction}

            {:error, err} ->
              raise err
          end

        {:error, err} ->
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
        emit_exception(span_metadata, e, start_time, __STACKTRACE__)
        reraise e, __STACKTRACE__
    end
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
