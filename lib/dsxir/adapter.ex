defmodule Dsxir.Adapter do
  @moduledoc """
  Adapter behaviour: turn a signature + inputs + demos into LM messages, and
  parse the LM response back into a typed field map.

  Two implementations ship in v0:

    * `Dsxir.Adapter.Chat` — `[[ ## marker ## ]]` text protocol, default.
    * `Dsxir.Adapter.Json` — provider-native structured output, added later.
  """

  @type messages :: [Sycophant.Message.t()]
  @type lm_response :: String.t()
  @type signature :: module() | Dsxir.Signature.Compiled.t()

  @type adapter_error ::
          Dsxir.Errors.Adapter.ParseError.t()
          | Dsxir.Errors.Adapter.ZoiValidation.t()
          | Dsxir.Errors.Adapter.FallbackExhausted.t()

  @callback format(signature(), map(), list(), keyword()) :: messages()
  @callback parse(signature(), lm_response() | map(), keyword()) ::
              {:ok, map()} | {:error, adapter_error()}
  @callback lm_mode() :: :text | :object
  @callback format_and_call(signature(), map(), list(), keyword()) ::
              {:ok, map(), Dsxir.LM.usage(), term()}
              | {:fallback, Exception.t()}

  @optional_callbacks [lm_mode: 0, format_and_call: 4]
end
