defmodule Dsxir.Optimizer.KNNFewShot do
  @moduledoc """
  Per-call dynamic demo selection optimizer.

  At compile time, embeds the trainset under a snapshotted embedder and builds
  a per-predictor index. At inference time (via the runtime hook in
  `Dsxir.Module.Runtime.call/4`), each call's inputs are embedded with the
  same embedder and the top-K nearest examples are passed as demos.

  ## Options

    * `:k` (default `5`) — neighbors returned per call. Must be `>= 1`.
    * `:embedder` — `{impl_module, config}` tuple. The config MUST include a
      `:model` key; it becomes the `embedder_id` on the resulting strategy and
      a missing `:model` returns
      `{:error, %Dsxir.Errors.Invalid.Configuration{key: :embedder, reason: :missing_model}}`
      at compile. Default: snapshot of `Dsxir.Settings.resolve(:lm)` at compile
      time. Credentials are stripped before storage.
    * `:embed_fields` (default `:all`) — `:all` or `[atom()]` subset of each
      predictor's signature input fields. Validated per predictor.

  The metric argument is accepted (Optimizer behaviour uniformity) and
  ignored. The trace and forward path are never invoked.

  ## Returned stats

      %{k: pos_integer(),
        embedder_id: String.t(),
        entries_per_predictor: %{atom() => non_neg_integer()},
        embedding_tokens: non_neg_integer(),
        compile_duration_ms: non_neg_integer()}

  `compiled_with` and `trainset_hash` are written onto `program.metadata`.
  """

  @behaviour Dsxir.Optimizer

  alias Dsxir.DemoStrategy.KNN
  alias Dsxir.DemoStrategy.KNN.Entry
  alias Dsxir.Errors
  alias Dsxir.Module.Info, as: ModuleInfo
  alias Dsxir.Program
  alias Dsxir.Retrieval.Embedder
  alias Dsxir.Settings
  alias Dsxir.Signature.Runtime, as: SignatureRuntime

  @default_k 5

  @impl Dsxir.Optimizer
  def compile(_student, [], _metric, _opts) do
    {:error, %Errors.Invalid.Trainset{reason: :empty, example: nil}}
  end

  def compile(%Program{} = student, trainset, _metric, opts)
      when is_list(trainset) and is_list(opts) do
    t0 = System.monotonic_time(:millisecond)

    with :ok <- validate_trainset(trainset),
         {:ok, k} <- validate_k(Keyword.get(opts, :k, @default_k)),
         {:ok, {impl, raw_config} = embedder_tuple} <-
           resolve_embedder(Keyword.get(opts, :embedder)),
         {:ok, embedder_id} <- validate_embedder_id(raw_config),
         embed_fields <- Keyword.get(opts, :embed_fields, :all),
         decls <- ModuleInfo.module(student.module),
         {:ok, per_predictor_entries, total_tokens} <-
           build_indices(decls, trainset, embedder_tuple, embed_fields) do
      stripped_config = KNN.strip_credentials(raw_config)
      stripped_embedder = {impl, stripped_config}

      compiled =
        per_predictor_entries
        |> Enum.reduce(student, fn {name, entries}, prog ->
          state = Program.get_state(prog, name)

          strategy = %KNN{
            k: k,
            embedder: stripped_embedder,
            embedder_id: embedder_id,
            embed_fields: embed_fields,
            entries: entries
          }

          Program.put_state(prog, name, %{state | demos: [], demo_strategy: strategy})
        end)
        |> stamp_metadata(trainset)

      stats = %{
        k: k,
        embedder_id: embedder_id,
        entries_per_predictor:
          Map.new(per_predictor_entries, fn {name, entries} -> {name, length(entries)} end),
        embedding_tokens: total_tokens,
        compile_duration_ms: System.monotonic_time(:millisecond) - t0
      }

      {:ok, compiled, stats}
    end
  end

  defp validate_trainset(trainset) do
    case Enum.find(trainset, fn ex -> not match?(%Dsxir.Example{}, ex) end) do
      nil -> :ok
      offender -> {:error, %Errors.Invalid.Trainset{reason: :not_an_example, example: offender}}
    end
  end

  defp validate_k(k) when is_integer(k) and k >= 1, do: {:ok, k}

  defp validate_k(k) do
    {:error, %Errors.Invalid.Configuration{key: :k, value: k, reason: :must_be_positive}}
  end

  defp resolve_embedder(nil) do
    case Settings.resolve(:lm) do
      {impl, config} when is_atom(impl) and is_list(config) ->
        {:ok, {impl, config}}

      _ ->
        {:error,
         %Errors.Invalid.Configuration{
           key: :embedder,
           value: nil,
           reason: :no_embedder_resolvable
         }}
    end
  end

  defp resolve_embedder({impl, config}) when is_atom(impl) and is_list(config) do
    {:ok, {impl, config}}
  end

  defp resolve_embedder(other) do
    {:error,
     %Errors.Invalid.Configuration{
       key: :embedder,
       value: other,
       reason: :expected_impl_config_tuple
     }}
  end

  defp build_indices(decls, trainset, embedder_tuple, embed_fields) do
    decls
    |> Enum.reduce_while(
      {:ok, [], 0},
      &index_predictor(&1, &2, trainset, embedder_tuple, embed_fields)
    )
    |> case do
      {:ok, list, total} -> {:ok, Enum.reverse(list), total}
      err -> err
    end
  end

  defp index_predictor(decl, {:ok, acc, total}, trainset, embedder_tuple, embed_fields) do
    input_names = predictor_input_names(decl)

    case validate_embed_fields(embed_fields, input_names) do
      :ok ->
        embed_predictor(decl, acc, total, trainset, embedder_tuple, embed_fields, input_names)

      {:error, err} ->
        {:halt, {:error, %{err | value: %{predictor: decl.name, field: err.value}}}}
    end
  end

  defp embed_predictor(decl, acc, total, trainset, embedder_tuple, embed_fields, input_names) do
    texts = render_examples(trainset, input_names, embed_fields)

    case embed_batch(embedder_tuple, texts) do
      {:ok, vectors, usage} ->
        entries = build_entries(vectors, trainset)
        tokens_in = sum_tokens(total, usage[:tokens_in])
        {:cont, {:ok, [{decl.name, entries} | acc], tokens_in}}

      {:error, err} ->
        {:halt, {:error, err}}
    end
  end

  defp build_entries(vectors, trainset) do
    vectors
    |> Enum.zip(trainset)
    |> Enum.map(fn {vec, ex} -> %Entry{embedding: vec, example: ex} end)
  end

  defp sum_tokens(total, nil), do: total
  defp sum_tokens(total, n) when is_integer(n), do: total + n

  defp predictor_input_names(decl) do
    decl.signature
    |> SignatureRuntime.inputs()
    |> Enum.map(& &1.name)
  end

  defp validate_embed_fields(:all, _input_names), do: :ok

  defp validate_embed_fields(fields, input_names) when is_list(fields) do
    valid = MapSet.new(input_names)

    case Enum.find(fields, fn f -> not MapSet.member?(valid, f) end) do
      nil ->
        :ok

      bad ->
        {:error,
         %Errors.Invalid.Configuration{
           key: :embed_fields,
           value: bad,
           reason: :unknown_field
         }}
    end
  end

  defp render_examples(trainset, input_names, embed_fields) do
    fields = if embed_fields == :all, do: input_names, else: embed_fields

    Enum.map(trainset, fn %Dsxir.Example{data: data} ->
      projected = Map.take(data, fields)
      Dsxir.DemoStrategy.KNN.EmbedText.render(projected, embed_fields)
    end)
  end

  defp embed_batch({impl, config}, texts) do
    embedder = %Embedder{}

    Settings.context([lm: {impl, config}], fn ->
      Embedder.embed(embedder, texts)
    end)
  end

  defp validate_embedder_id(config) do
    case Keyword.fetch(config, :model) do
      {:ok, model} ->
        {:ok, to_string(model)}

      :error ->
        {:error,
         %Errors.Invalid.Configuration{
           key: :embedder,
           value: config,
           reason: :missing_model
         }}
    end
  end

  defp stamp_metadata(%Program{} = prog, trainset) do
    metadata =
      prog.metadata
      |> Map.put(:compiled_with, __MODULE__)
      |> Map.put(:score, nil)
      |> Map.put(:trainset_hash, trainset_hash(trainset))

    %{prog | metadata: metadata}
  end

  defp trainset_hash(trainset) do
    :crypto.hash(:sha256, :erlang.term_to_binary(trainset))
    |> Base.encode16(case: :lower)
  end
end
