defmodule Dsxir.Errors do
  @moduledoc """
  Splode aggregator for dsxir-originated errors.

  Six classes, ordered by precedence (first non-empty class wins on aggregation):

    * `:halted` - explicit policy halts (e.g. `call_plugs` returning `{:halt, _}`).
    * `:invalid` - configuration / input / signature shape problems.
    * `:adapter` - parse, validation, and fallback exhaustion errors.
    * `:lm` - upstream LM transport / quota / context-window errors.
    * `:framework` - dsxir internal bugs surfaced as typed errors.
    * `:unknown` - Splode fallback when an error cannot be classified.

  Every dsxir-originated error carries a `path` field populated as the call
  descends nested predictors — e.g. `[:extract_actions, :action_items]`.
  """

  use Splode,
    error_classes: [
      halted: Dsxir.Errors.Halted,
      invalid: Dsxir.Errors.Invalid,
      adapter: Dsxir.Errors.Adapter,
      lm: Dsxir.Errors.LM,
      framework: Dsxir.Errors.Framework,
      unknown: Dsxir.Errors.Unknown
    ],
    unknown_error: Dsxir.Errors.Unknown.Unknown,
    filter_stacktraces: [
      Dsxir.Module.Runtime,
      Dsxir.Settings,
      "Dsxir.Adapter.",
      "Dsxir.Predictor."
    ]

  @doc """
  Return the splode class of `error` (one of `:halted`, `:invalid`, `:adapter`,
  `:lm`, `:framework`, `:unknown`). Falls back to `:unknown` when the value is
  not a classified dsxir error.
  """
  @spec class_of(any()) :: atom()
  def class_of(%{class: class}) when is_atom(class), do: class
  def class_of(_), do: :unknown
end
