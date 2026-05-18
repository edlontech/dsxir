defmodule Dsxir.DemoStrategy.KNN do
  @moduledoc """
  Per-call demo resolver: embed the inputs, cosine-search the index, return
  the top-K examples as demos for this call.

  Held on `%Dsxir.Program.State{demo_strategy: %KNN{}}`. Compiled by
  `Dsxir.Optimizer.KNNFewShot`. Used by `Dsxir.Module.Runtime.call/4`.
  """

  alias Dsxir.DemoStrategy.KNN.EmbedText
  alias Dsxir.Errors
  alias Dsxir.Retrieval.Cosine
  alias Dsxir.Settings

  @credential_keys [:api_key, :base_url, :headers]

  defmodule Entry do
    @moduledoc "One indexed (embedding, example) pair."
    @enforce_keys [:embedding, :example]
    defstruct [:embedding, :example]

    @type t :: %__MODULE__{embedding: [float()], example: Dsxir.Example.t()}

    defimpl Inspect do
      import Inspect.Algebra

      def inspect(%Dsxir.DemoStrategy.KNN.Entry{embedding: e, example: ex}, opts) do
        concat([
          "#Dsxir.DemoStrategy.KNN.Entry<dim: ",
          Integer.to_string(length(e)),
          ", example: ",
          to_doc(ex, opts),
          ">"
        ])
      end
    end
  end

  @enforce_keys [:k, :embedder, :embedder_id, :embed_fields, :entries]
  defstruct [:k, :embedder, :embedder_id, :embed_fields, :entries]

  @type t :: %__MODULE__{
          k: pos_integer(),
          embedder: {module(), keyword()},
          embedder_id: String.t(),
          embed_fields: :all | [atom()],
          entries: [Entry.t()]
        }

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%Dsxir.DemoStrategy.KNN{} = strategy, _opts) do
      parts = [
        "k: " <> Integer.to_string(strategy.k),
        "embedder_id: " <> inspect(strategy.embedder_id),
        "embed_fields: " <> inspect(strategy.embed_fields),
        "entries: " <> Integer.to_string(length(strategy.entries))
      ]

      concat(["#Dsxir.DemoStrategy.KNN<", Enum.join(parts, ", "), ">"])
    end
  end

  @doc """
  Resolve K nearest demos for `inputs`. Emits `[:dsxir, :knn, :resolve]` on
  success; emits `[:dsxir, :knn, :insufficient_entries]` when fewer than `k`
  entries are available. Raises the underlying `Dsxir.Errors.LM.*` on
  embedder failure.
  """
  @spec resolve(t(), map(), keyword()) :: [Dsxir.Example.t()]
  def resolve(%__MODULE__{} = strategy, inputs, opts \\ []) when is_map(inputs) do
    metadata = Settings.resolve(:metadata, %{})
    predictor = Keyword.get(opts, :predictor)
    start_time = System.monotonic_time()

    query_text = EmbedText.render(inputs, strategy.embed_fields)
    {embed_duration, query_vector} = embed_query(strategy, query_text)

    requested_k = strategy.k
    available = length(strategy.entries)

    if requested_k > available do
      :telemetry.execute(
        [:dsxir, :knn, :insufficient_entries],
        %{},
        Map.merge(metadata, %{
          predictor: predictor,
          requested_k: requested_k,
          available: available
        })
      )
    end

    top =
      strategy.entries
      |> Enum.map(fn %Entry{embedding: e, example: ex} ->
        {Cosine.similarity(query_vector, e), ex}
      end)
      |> Enum.sort_by(fn {score, _ex} -> score end, :desc)
      |> Enum.take(min(requested_k, available))
      |> Enum.map(fn {_score, ex} -> ex end)

    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:dsxir, :knn, :resolve],
      %{duration: duration, k_returned: length(top), embed_duration: embed_duration},
      Map.merge(metadata, %{predictor: predictor, embedder_id: strategy.embedder_id})
    )

    top
  end

  defp embed_query(%__MODULE__{embedder: {impl, base_config}}, text) do
    config = merge_credentials(base_config)
    t0 = System.monotonic_time()

    case impl.embed(config, [text], []) do
      {:ok, [vector], _usage} ->
        {System.monotonic_time() - t0, vector}

      {:ok, vectors, _usage} ->
        raise %Errors.Framework.PredictorError{
          predictor: __MODULE__,
          signature: nil,
          inner: nil,
          reason: :unexpected_embed_count,
          trajectory: %{got: length(vectors), expected: 1}
        }

      {:error, %Errors.LM.RequestFailed{} = err} ->
        raise err

      {:error, %{__struct__: struct} = err}
      when struct in [Errors.LM.ContextWindow, Errors.LM.RateLimited, Errors.LM.Authentication] ->
        raise err

      {:error, other} ->
        raise %Errors.LM.RequestFailed{
          model_id: Keyword.get(base_config, :model),
          status: nil,
          parent_error: other
        }
    end
  end

  defp merge_credentials(base_config) do
    case Settings.resolve(:lm) do
      {_impl, lm_config} when is_list(lm_config) ->
        lm_config
        |> Keyword.take(@credential_keys)
        |> Enum.reduce(base_config, &put_missing/2)

      _ ->
        base_config
    end
  end

  defp put_missing({k, v}, acc) do
    case Keyword.has_key?(acc, k) do
      true -> acc
      false -> Keyword.put(acc, k, v)
    end
  end

  @doc "Strip credential keys from a config keyword list. Used at serialize time."
  @spec strip_credentials(keyword()) :: keyword()
  def strip_credentials(config) when is_list(config) do
    Keyword.drop(config, @credential_keys)
  end
end
