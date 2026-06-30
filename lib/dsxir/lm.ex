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
  @type usage :: Dsxir.Cost.t()

  @typedoc """
  A streaming sink passed in `opts` under `:stream`. The 1-arity form is invoked
  once per `Dsxir.LM.StreamChunk`; the 2-arity accumulator form threads `acc`
  across chunks (callers carry parser state without a process). Implementations
  translate their provider's chunk type into `Dsxir.LM.StreamChunk` before
  invoking the sink, and still return the final assembled result.
  """
  @type stream_sink ::
          (Dsxir.LM.StreamChunk.t() -> term())
          | {term(), (Dsxir.LM.StreamChunk.t(), term() -> term())}

  @callback generate_text(config(), messages(), opts()) ::
              {:ok, String.t(), usage()} | {:error, term()}

  @callback generate_object(config(), messages(), Zoi.schema(), opts()) ::
              {:ok, map(), usage()} | {:error, term()}

  @callback embed(config(), [String.t()], opts()) ::
              {:ok, [[float()]], usage()} | {:error, term()}

  @optional_callbacks [generate_object: 4, embed: 3]

  @doc "Zero-valued `Dsxir.Cost` used when the upstream LM reported no usage."
  @spec empty_usage() :: Dsxir.Cost.t()
  def empty_usage, do: Dsxir.Cost.zero()

  @doc """
  Dispatch a `generate_text` call to the impl module currently active in
  `Dsxir.Settings`. Per-call `opts` are merged on top of the config from settings.
  Raises `Dsxir.Errors.Invalid.Configuration` when `:lm` is unset or malformed.
  """
  @spec generate_text(messages(), opts()) :: {:ok, String.t(), usage()} | {:error, term()}
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

  @doc """
  Dispatch a `generate_object` call to the impl module currently active in
  `Dsxir.Settings`, requesting a structured object validated against `schema`.

  Per-call `opts` are merged on top of the config from settings. Raises
  `Dsxir.Errors.Invalid.Configuration` when `:lm` is unset, malformed, or when
  the configured impl does not implement the optional `generate_object/4`
  callback.
  """
  @spec generate_object(messages(), Zoi.schema(), opts()) ::
          {:ok, map(), usage()} | {:error, term()}
  def generate_object(messages, schema, opts \\ [])
      when is_list(messages) and is_list(opts) do
    case Dsxir.Settings.resolve(:lm) do
      {impl, config} when is_atom(impl) and is_list(config) ->
        if Code.ensure_loaded?(impl) and function_exported?(impl, :generate_object, 4) do
          impl.generate_object(config, messages, schema, opts)
        else
          raise %Dsxir.Errors.Invalid.Configuration{
            key: :lm,
            value: impl,
            reason: :generate_object_unsupported
          }
        end

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

  @doc """
  Dispatch an `embed` call to the impl module currently active in
  `Dsxir.Settings`. Per-call `opts` are merged on top of the config. Raises
  `Dsxir.Errors.Invalid.Configuration` when `:lm` is unset, malformed, or the
  configured impl does not implement the optional `embed/3` callback. Emits
  `[:dsxir, :lm, :embed, :stop]` on a successful result.
  """
  @spec embed([String.t()], opts()) :: {:ok, [[float()]], usage()} | {:error, term()}
  def embed(inputs, opts \\ []) when is_list(inputs) and is_list(opts) do
    case Dsxir.Settings.resolve(:lm) do
      {impl, config} when is_atom(impl) and is_list(config) ->
        if Code.ensure_loaded?(impl) and function_exported?(impl, :embed, 3) do
          start_time = System.monotonic_time()
          result = impl.embed(config, inputs, opts)
          maybe_emit_embed_stop(result, config, opts, start_time)
          result
        else
          raise %Dsxir.Errors.Invalid.Configuration{
            key: :lm,
            value: impl,
            reason: :embed_unsupported
          }
        end

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

  defp maybe_emit_embed_stop({:ok, _vectors, %Dsxir.Cost{} = cost}, config, opts, start_time) do
    duration = System.monotonic_time() - start_time
    base_metadata = Dsxir.Settings.resolve(:metadata, %{})

    model =
      Keyword.get(opts, :embedding_model, Keyword.get(config, :embedding_model)) ||
        Keyword.get(config, :model)

    Dsxir.Telemetry.emit(
      Dsxir.Telemetry.lm_embed_stop(),
      Map.put(Dsxir.Cost.to_measurements(cost), :duration, duration),
      Map.merge(base_metadata, %{
        model: model,
        cost: cost,
        _cost_scope: Dsxir.Settings.resolve(:_cost_scope, [])
      })
    )
  end

  defp maybe_emit_embed_stop(_result, _config, _opts, _start_time), do: :ok
end
