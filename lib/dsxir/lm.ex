defmodule Dsxir.LM do
  @moduledoc """
  Behaviour for LM providers.

  Predictors and adapters issue LM requests through this contract; they never reach
  into a specific provider SDK directly. The active impl plus its config live in
  `Dsxir.Settings` under `:lm` as a `{impl_module, config :: keyword()}` tuple. The
  dispatcher functions on this module read `:lm` from settings, merge per-call opts
  on top of the config, and invoke the impl.

  The behaviour declares the callbacks predictors and adapters call. New callbacks
  (structured output for the Json adapter, streaming for the Chat adapter,
  embeddings for the in-memory retriever) extend the behaviour when their consumers
  land — old impls keep working while their new-callback path raises until
  implemented.

  In tests, stub impl callbacks with `mimic` rather than building bespoke fakes.
  """

  @type config :: keyword()
  @type messages :: [map()]
  @type opts :: keyword()

  @callback generate_text(config(), messages(), opts()) ::
              {:ok, String.t()} | {:error, term()}

  @doc """
  Dispatch a `generate_text` call to the impl module currently active in
  `Dsxir.Settings`. Per-call `opts` are merged on top of the config from settings.
  Raises `Dsxir.Errors.Invalid.Configuration` when `:lm` is unset or malformed.
  """
  @spec generate_text(messages(), opts()) :: {:ok, String.t()} | {:error, term()}
  def generate_text(messages, opts \\ []) when is_list(messages) and is_list(opts) do
    case Dsxir.Settings.resolve(:lm) do
      {impl, config} when is_atom(impl) and is_list(config) ->
        impl.generate_text(config, messages, opts)

      nil ->
        raise %Dsxir.Errors.Invalid.Configuration{
          key: :lm,
          value: nil,
          reason: :no_lm_configured
        }

      other ->
        raise %Dsxir.Errors.Invalid.Configuration{
          key: :lm,
          value: other,
          reason: :expected_impl_config_tuple
        }
    end
  end
end
