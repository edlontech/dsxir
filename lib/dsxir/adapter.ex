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

  @type adapter_error ::
          Dsxir.Errors.Adapter.ParseError.t()
          | Dsxir.Errors.Adapter.ZoiValidation.t()
          | Dsxir.Errors.Adapter.FallbackExhausted.t()

  @callback format(module(), map(), list(), keyword()) :: messages()
  @callback parse(module(), lm_response(), keyword()) ::
              {:ok, map()} | {:error, adapter_error()}
end
