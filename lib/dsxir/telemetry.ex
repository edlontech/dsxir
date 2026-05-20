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
      [:dsxir, :optimizer, :insufficient_demos]

      [:dsxir, :miprov2, :proposer]
      [:dsxir, :miprov2, :rerank]

      [:dsxir, :evaluate, :item]
      [:dsxir, :evaluate, :stop]

      [:dsxir, :runtime_program, :skipped]

  ## Always-present keys

  The `:error_class` metadata key on `[:dsxir, :predictor, :stop]` and
  `[:dsxir, :predictor, :exception]` is always present, with value `nil` when no
  error occurred. Subscribers should branch on `nil`, never on `Map.has_key?/2`.

  Token measurements (`tokens_in`, `tokens_out`, `cost`) follow the same
  always-present-nil convention on `[:dsxir, :predictor, :stop]`. They are
  populated by `Dsxir.LM` implementations via the `Dsxir.LM.usage()` shape;
  when the upstream provider did not report usage, the impl returns
  `Dsxir.LM.empty_usage/0` (all three keys `nil`).

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

  `[:dsxir, :optimizer, :insufficient_demos]`

    * **Measurements:** `%{requested: non_neg_integer(), got: non_neg_integer()}`.
    * **Metadata:** `%{predictor: atom(), requested: non_neg_integer(),
      got: non_neg_integer(), reached_examples: non_neg_integer(),
      total_examples: non_neg_integer(), degraded_excluded: boolean()}`.

  Emitted once per predictor whose final bootstrapped pool has fewer than
  `max_bootstrapped_demos` entries. Never raises; subscribers may use the event
  to surface trainset-coverage gaps without aborting compilation.

  Subscribers branch on `nil` for `score` and `error_class`; never on
  `Map.has_key?/2`.

  ## Runtime-program events

  `[:dsxir, :runtime_program, :skipped]`

    * **Measurements:** `%{}`.
    * **Metadata:** `%{node: atom(), reason: :guard_false | :upstream_required_skipped,
      program_id: term(), program_version: term()}`.

  Emitted by the runtime-program executor each time a graph node is skipped,
  either because a declared guard returned `false` or because an upstream
  required-input dependency was itself skipped. Documented here; produced by
  the executor.
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

  @miprov2_proposer [:dsxir, :miprov2, :proposer]
  @miprov2_rerank [:dsxir, :miprov2, :rerank]

  @evaluate_item [:dsxir, :evaluate, :item]
  @evaluate_stop [:dsxir, :evaluate, :stop]

  @type event :: [atom(), ...]

  @doc "Event name for `[:dsxir, :predictor, :start]`."
  @spec predictor_start() :: event()
  def predictor_start, do: @predictor_start

  @doc "Event name for `[:dsxir, :predictor, :stop]`."
  @spec predictor_stop() :: event()
  def predictor_stop, do: @predictor_stop

  @doc "Event name for `[:dsxir, :predictor, :exception]`."
  @spec predictor_exception() :: event()
  def predictor_exception, do: @predictor_exception

  @doc "Event name for `[:dsxir, :adapter, :format]`."
  @spec adapter_format() :: event()
  def adapter_format, do: @adapter_format

  @doc "Event name for `[:dsxir, :adapter, :parse]`."
  @spec adapter_parse() :: event()
  def adapter_parse, do: @adapter_parse

  @doc "Event name for `[:dsxir, :adapter, :fallback]`."
  @spec adapter_fallback() :: event()
  def adapter_fallback, do: @adapter_fallback

  @doc "Event name for `[:dsxir, :optimizer, :start]`."
  @spec optimizer_start() :: event()
  def optimizer_start, do: @optimizer_start

  @doc "Event name for `[:dsxir, :optimizer, :stop]`."
  @spec optimizer_stop() :: event()
  def optimizer_stop, do: @optimizer_stop

  @doc "Event name for `[:dsxir, :optimizer, :trial]`."
  @spec optimizer_trial() :: event()
  def optimizer_trial, do: @optimizer_trial

  @doc "Event name for `[:dsxir, :optimizer, :item_error]`."
  @spec optimizer_item_error() :: event()
  def optimizer_item_error, do: @optimizer_item_error

  @doc "Event name for `[:dsxir, :miprov2, :proposer]` (point-in-time proposer outcome)."
  @spec miprov2_proposer() :: event()
  def miprov2_proposer, do: @miprov2_proposer

  @doc "Event name for `[:dsxir, :miprov2, :rerank]` (point-in-time full-eval rerank)."
  @spec miprov2_rerank() :: event()
  def miprov2_rerank, do: @miprov2_rerank

  @doc "Event name for `[:dsxir, :evaluate, :item]`."
  @spec evaluate_item() :: event()
  def evaluate_item, do: @evaluate_item

  @doc "Event name for `[:dsxir, :evaluate, :stop]`."
  @spec evaluate_stop() :: event()
  def evaluate_stop, do: @evaluate_stop

  @doc "Thin wrapper over `:telemetry.execute/3`."
  @spec emit(event(), map(), map()) :: :ok
  def emit(event, measurements \\ %{}, metadata \\ %{})
      when is_list(event) and is_map(measurements) and is_map(metadata) do
    :telemetry.execute(event, measurements, metadata)
  end
end
