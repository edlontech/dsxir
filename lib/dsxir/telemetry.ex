defmodule Dsxir.Telemetry do
  @moduledoc """
  Event-name constants and the `emit/3` helper for dsxir telemetry.

  Documents the full event vocabulary and exposes a thin wrapper over
  `:telemetry.execute/3`. Producers (predictors, adapters, optimizers, evaluate)
  and subscribers (the `Dsxir.History` ETS handler, the upstream LM relay,
  user-supplied handlers) attach as their consumers land.

  ## Event vocabulary

      [:dsxir, :predictor, :start]
      [:dsxir, :predictor, :stop]
      [:dsxir, :predictor, :exception]

      [:dsxir, :adapter, :format]
      [:dsxir, :adapter, :parse]
      [:dsxir, :adapter, :fallback]

      [:dsxir, :optimizer, :start]
      [:dsxir, :optimizer, :stop]
      [:dsxir, :optimizer, :trial]
      [:dsxir, :optimizer, :item_error]

      [:dsxir, :evaluate, :item]
      [:dsxir, :evaluate, :stop]

  ## Always-present keys

  The `:error_class` metadata key on `[:dsxir, :predictor, :stop]` and
  `[:dsxir, :predictor, :exception]` is always present, with value `nil` when no
  error occurred. Subscribers should branch on `nil`, never on `Map.has_key?/2`.

  Token measurements (`tokens_in`, `tokens_out`, `cost`) will follow the same
  always-present-nil convention when relayed from the upstream LM impl. Until
  that wiring lands, those keys are absent from emitted measurements — once
  they appear they will follow the convention.

  ## Optimizer events

  `[:dsxir, :optimizer, :start]`

    * **Measurements:** `%{system_time: integer()}`.
    * **Metadata:** `%{optimizer: module(), trainset_size: non_neg_integer(), error_class: nil}`.

  `[:dsxir, :optimizer, :stop]`

    * **Measurements:** `%{duration: integer(), score: nil | float()}`. `score` is
      `nil` for optimizers that do not compute a holdout score during compile
      (e.g. `Dsxir.Optimizer.LabeledFewShot`, `Dsxir.Optimizer.BootstrapFewShot`);
      future optimizers (MIPROv2, GEPA) may populate it.
    * **Metadata:** `%{optimizer: module(), trainset_size: non_neg_integer(),
      error_class: nil | atom()}`. `error_class` is `nil` on success and the
      aggregated error class atom on failure.

  `[:dsxir, :optimizer, :trial]`

    * **Measurements:** `%{score: float()}`. Coerced metric value for the trial.
    * **Metadata:** `%{optimizer: module(), round: pos_integer(),
      example_index: non_neg_integer(), kept: boolean(), error_class: nil}`.

  `[:dsxir, :optimizer, :item_error]`

    * **Measurements:** `%{system_time: integer()}`.
    * **Metadata:** `%{optimizer: module(), round: pos_integer(),
      example_index: non_neg_integer(), error: Exception.t(),
      error_class: atom()}`.

  Subscribers branch on `nil` for `score` and `error_class`; never on
  `Map.has_key?/2`.
  """

  @predictor_start [:dsxir, :predictor, :start]
  @predictor_stop [:dsxir, :predictor, :stop]
  @predictor_exception [:dsxir, :predictor, :exception]

  @adapter_format [:dsxir, :adapter, :format]
  @adapter_parse [:dsxir, :adapter, :parse]
  @adapter_fallback [:dsxir, :adapter, :fallback]

  @optimizer_start [:dsxir, :optimizer, :start]
  @optimizer_stop [:dsxir, :optimizer, :stop]
  @optimizer_trial [:dsxir, :optimizer, :trial]
  @optimizer_item_error [:dsxir, :optimizer, :item_error]

  @evaluate_item [:dsxir, :evaluate, :item]
  @evaluate_stop [:dsxir, :evaluate, :stop]

  def predictor_start, do: @predictor_start
  def predictor_stop, do: @predictor_stop
  def predictor_exception, do: @predictor_exception
  def adapter_format, do: @adapter_format
  def adapter_parse, do: @adapter_parse
  def adapter_fallback, do: @adapter_fallback
  def optimizer_start, do: @optimizer_start
  def optimizer_stop, do: @optimizer_stop
  def optimizer_trial, do: @optimizer_trial
  def optimizer_item_error, do: @optimizer_item_error
  def evaluate_item, do: @evaluate_item
  def evaluate_stop, do: @evaluate_stop

  @spec emit([atom()], map(), map()) :: :ok
  def emit(event, measurements \\ %{}, metadata \\ %{})
      when is_list(event) and is_map(measurements) and is_map(metadata) do
    :telemetry.execute(event, measurements, metadata)
  end
end
