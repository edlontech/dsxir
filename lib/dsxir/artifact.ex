defmodule Dsxir.Artifact do
  @moduledoc """
  Encode and decode `Dsxir.Program` save/load artifacts.

  The on-disk JSON shape mirrors DSPy structurally:

      {
        "<predictor_name>": {"instructions": String | null, "demos": [Map, ...]},
        ...,
        "_metadata": {"compiled_with": ..., "score": ..., "trainset_hash": ...}
      }

  `save/2` writes one program. `load/3` reads one program into a target module
  and validates the artifact's predictor + field shape against the target's
  signatures, raising `Dsxir.Errors.Invalid.SignatureMismatch` on any drift.
  """

  alias Dsxir.DemoStrategy.KNN
  alias Dsxir.DemoStrategy.KNN.Entry
  alias Dsxir.Errors
  alias Dsxir.Module.Info, as: ModuleInfo
  alias Dsxir.Program
  alias Dsxir.Signature.Runtime, as: SignatureRuntime

  @reserved_metadata_key "_metadata"

  @doc """
  Write `prog` to `path` as pretty JSON. Returns `{:ok, path}` on success or
  `{:error, exception}` when encoding or I/O fails. The target directory is
  created if missing.
  """
  @spec save(Program.t(), Path.t()) :: {:ok, Path.t()} | {:error, Exception.t()}
  def save(%Program{} = prog, path) when is_binary(path) do
    File.mkdir_p!(Path.dirname(path))

    try do
      case Jason.encode(encode(prog), pretty: true) do
        {:ok, json} ->
          File.write!(path, json <> "\n")
          {:ok, path}

        {:error, %Jason.EncodeError{} = err} ->
          {:error, err}

        {:error, %Protocol.UndefinedError{} = err} ->
          {:error, err}
      end
    rescue
      e in [Jason.EncodeError, Protocol.UndefinedError, File.Error] ->
        {:error, e}
    end
  end

  @doc """
  Bang variant of `save/2`. Returns the path on success and raises the
  underlying exception on failure.
  """
  @spec save!(Program.t(), Path.t()) :: Path.t()
  def save!(%Program{} = prog, path) when is_binary(path) do
    case save(prog, path) do
      {:ok, ^path} -> path
      {:error, err} -> raise err
    end
  end

  @doc false
  @spec encode(Program.t()) :: map()
  def encode(%Program{module: user_module, predictors: predictors, metadata: metadata}) do
    decls = ModuleInfo.module(user_module)

    per_predictor =
      Map.new(decls, fn decl ->
        state = Map.get(predictors, decl.name, %Program.State{})
        {Atom.to_string(decl.name), encode_predictor(state, decl.signature)}
      end)

    Map.put(per_predictor, @reserved_metadata_key, encode_metadata(metadata))
  end

  defp encode_predictor(%Program.State{} = state, signature) do
    base = %{
      "instructions" => instructions_for(state, signature),
      "demos" => Enum.map(state.demos, &encode_demo/1)
    }

    case state.demo_strategy do
      nil -> base
      strategy -> Map.put(base, "demo_strategy", encode_demo_strategy(strategy))
    end
  end

  defp encode_demo_strategy(%KNN{} = strategy), do: encode_knn(strategy)

  defp encode_knn(%KNN{
         k: k,
         embedder: {impl, config},
         embedder_id: embedder_id,
         embed_fields: embed_fields,
         entries: entries
       }) do
    stripped = KNN.strip_credentials(config)

    %{
      "kind" => "knn",
      "k" => k,
      "embedder" => %{
        "impl" => Atom.to_string(impl),
        "config" => encode_embedder_config(stripped)
      },
      "embedder_id" => embedder_id,
      "embed_fields" => encode_embed_fields(embed_fields),
      "entries" => Enum.map(entries, &encode_entry/1)
    }
  end

  defp encode_embedder_config(config) when is_list(config) do
    Map.new(config, fn {k, v} -> {Atom.to_string(k), v} end)
  end

  defp encode_embed_fields(:all), do: "all"
  defp encode_embed_fields(fields) when is_list(fields), do: Enum.map(fields, &Atom.to_string/1)

  defp encode_entry(%Entry{embedding: embedding, example: %Dsxir.Example{data: data}}) do
    %{
      "embedding" => embedding,
      "example" => stringify_keys(data)
    }
  end

  defp instructions_for(%Program.State{instructions_override: override}, _signature)
       when is_binary(override),
       do: override

  defp instructions_for(%Program.State{instructions_override: nil}, signature),
    do: SignatureRuntime.instruction(signature)

  defp encode_demo(%Dsxir.Demo{example: %Dsxir.Example{data: data}, kind: kind}) do
    data
    |> stringify_keys()
    |> Map.put("_kind", Atom.to_string(kind))
  end

  defp encode_demo(%Dsxir.Example{data: data}) do
    data
    |> stringify_keys()
    |> Map.put("_kind", "labeled")
  end

  defp encode_demo(demo) when is_map(demo), do: stringify_keys(demo)

  defp encode_metadata(metadata) do
    Map.new(metadata, fn {k, v} -> {Atom.to_string(k), encode_metadata_value(k, v)} end)
  end

  defp encode_metadata_value(:compiled_with, mod), do: stringify_module(mod)
  defp encode_metadata_value(:_miprov2_stats, value), do: encode_miprov2_stats(value)
  defp encode_metadata_value(_key, value), do: encode_jsonable(value)

  # Encodes a `%Dsxir.Optimizer.MIPROv2.Stats{}` (or any compatible map) into a
  # plain string-keyed map. Asymmetric round-trip: `hydrate_metadata_value/2`
  # leaves `"_miprov2_stats"` as a string-keyed map rather than rehydrating it
  # back into the original struct — mirrors how `compiled_with` degrades to nil
  # when the optimizer module is not loaded at hydrate time.
  defp encode_miprov2_stats(nil), do: nil

  defp encode_miprov2_stats(%{__struct__: _} = stats) do
    stats
    |> Map.from_struct()
    |> Map.delete(:__struct__)
    |> Map.new(fn {k, v} -> {Atom.to_string(k), encode_jsonable(v)} end)
  end

  defp encode_miprov2_stats(other), do: encode_jsonable(other)

  defp encode_jsonable(%{__struct__: _} = struct) do
    struct
    |> Map.from_struct()
    |> Map.delete(:__struct__)
    |> Map.new(fn {k, v} -> {Atom.to_string(k), encode_jsonable(v)} end)
  end

  defp encode_jsonable(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {encode_map_key(k), encode_jsonable(v)} end)
  end

  defp encode_jsonable(list) when is_list(list), do: Enum.map(list, &encode_jsonable/1)

  defp encode_jsonable(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&encode_jsonable/1)

  defp encode_jsonable(atom) when is_atom(atom) and not is_boolean(atom) and not is_nil(atom),
    do: Atom.to_string(atom)

  defp encode_jsonable(value), do: value

  defp encode_map_key(key) when is_binary(key), do: key
  defp encode_map_key(key) when is_atom(key), do: Atom.to_string(key)
  defp encode_map_key(key) when is_tuple(key), do: inspect(key)
  defp encode_map_key(key), do: to_string(key)

  defp stringify_module(nil), do: nil
  defp stringify_module(mod) when is_atom(mod), do: Atom.to_string(mod)

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  @doc """
  Read a saved artifact from `path` and hydrate it into a fresh program for
  `target_module`. Returns `{:ok, program}` or `{:error, exception}` on read,
  decode, or structural validation failures.
  """
  @spec load(module(), Path.t(), keyword()) :: {:ok, Program.t()} | {:error, Exception.t()}
  def load(target_module, path, _opts \\ []) when is_atom(target_module) and is_binary(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, decoded} <- Jason.decode(raw) do
      decode(target_module, decoded)
    else
      {:error, %Jason.DecodeError{} = err} ->
        {:error, err}

      {:error, reason} when is_atom(reason) ->
        {:error, %File.Error{path: path, action: "read", reason: reason}}
    end
  end

  @doc """
  Bang variant of `load/3`. Returns the program on success and raises the
  underlying exception on failure.
  """
  @spec load!(module(), Path.t(), keyword()) :: Program.t()
  def load!(target_module, path, opts \\ []) do
    case load(target_module, path, opts) do
      {:ok, prog} -> prog
      {:error, err} -> raise err
    end
  end

  @doc """
  Rebuild a `%Dsxir.Program{}` from an already-Jason-decoded artifact map. The
  companion to `encode/1` for inline (file-IO-free) serialization; `load/3` is
  the file path convenience built on this.

  Returns `{:ok, program}` or `{:error, %Dsxir.Errors.Invalid.SignatureMismatch{}}`
  when the persisted shape does not match the target module's declared
  predictors.
  """
  @spec decode(module(), map()) :: {:ok, Program.t()} | {:error, Exception.t()}
  def decode(target_module, decoded) when is_atom(target_module) and is_map(decoded) do
    decls = ModuleInfo.module(target_module)
    expected = expected_shape(decls)
    {metadata_payload, predictors_payload} = Map.pop(decoded, @reserved_metadata_key, %{})
    loaded = Map.new(predictors_payload, fn {name, body} -> {name, demo_keys_in(body)} end)

    case structural_diff(expected, loaded) do
      %{missing_predictors: [], extra_predictors: [], field_diffs: empty} when empty == %{} ->
        hydrate(target_module, decls, predictors_payload, metadata_payload)

      diff ->
        {:error,
         %Errors.Invalid.SignatureMismatch{
           module: target_module,
           expected: expected,
           loaded: loaded,
           diff: diff
         }}
    end
  end

  defp expected_shape(decls) do
    Map.new(decls, fn decl ->
      inputs = Enum.map(SignatureRuntime.inputs(decl.signature), & &1.name)
      outputs = Enum.map(SignatureRuntime.outputs(decl.signature), & &1.name)
      augmented = Dsxir.Predictor.augmented_outputs(decl.impl, decl.signature)
      {decl.name, %{inputs: inputs, outputs: outputs, augmented_outputs: augmented}}
    end)
  end

  defp demo_keys_in(%{"demos" => demos}) when is_list(demos) do
    Enum.map(demos, fn demo ->
      demo
      |> Map.delete("_kind")
      |> Map.keys()
      |> Enum.sort()
    end)
  end

  defp demo_keys_in(_), do: []

  defp structural_diff(expected, loaded) do
    expected_names = expected |> Map.keys() |> MapSet.new()

    loaded_names =
      loaded
      |> Map.keys()
      |> Enum.map(&safe_existing_atom/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    missing = expected_names |> MapSet.difference(loaded_names) |> Enum.sort()
    extra = loaded_names |> MapSet.difference(expected_names) |> Enum.sort()
    common = MapSet.intersection(expected_names, loaded_names)
    field_diffs = field_diffs(expected, loaded, common)

    %{
      missing_predictors: missing,
      extra_predictors: extra,
      field_diffs: Enum.into(field_diffs, %{})
    }
  end

  defp field_diffs(expected, loaded, common_names) do
    Enum.flat_map(common_names, fn name ->
      declared = MapSet.new(expected[name].inputs ++ expected[name].outputs)
      allowed = MapSet.union(declared, MapSet.new(expected[name].augmented_outputs))
      demo_lists = Map.fetch!(loaded, Atom.to_string(name))

      {missing, extra} = compare_fields(declared, allowed, demo_lists)

      if missing == [] and extra == [],
        do: [],
        else: [{name, %{missing_fields: missing, extra_fields: extra}}]
    end)
  end

  defp compare_fields(_declared, _allowed, []), do: {[], []}

  defp compare_fields(declared, allowed, demo_lists) do
    demo_keysets =
      Enum.map(demo_lists, fn keys ->
        keys |> Enum.map(&safe_existing_atom/1) |> Enum.reject(&is_nil/1) |> MapSet.new()
      end)

    intersection_present =
      Enum.reduce(demo_keysets, declared, fn keyset, acc -> MapSet.intersection(acc, keyset) end)

    union_extra =
      Enum.reduce(demo_keysets, MapSet.new(), fn keyset, acc -> MapSet.union(acc, keyset) end)

    missing = declared |> MapSet.difference(intersection_present) |> Enum.sort()
    extra = union_extra |> MapSet.difference(allowed) |> Enum.sort()
    {missing, extra}
  end

  defp safe_existing_atom(name) when is_binary(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> nil
  end

  defp safe_existing_atom(name) when is_atom(name), do: name

  defp hydrate(target_module, decls, predictors_payload, metadata_payload) do
    fresh = Program.new(target_module)

    result =
      Enum.reduce_while(decls, {:ok, fresh.predictors}, fn decl, {:ok, acc} ->
        payload = Map.get(predictors_payload, Atom.to_string(decl.name), %{})
        input_names = Enum.map(SignatureRuntime.inputs(decl.signature), & &1.name)
        demos = build_demos(Map.get(payload, "demos", []), input_names)
        instructions_override = payload["instructions"]

        case decode_demo_strategy(Map.get(payload, "demo_strategy"), input_names) do
          {:ok, demo_strategy} ->
            state = %Program.State{
              demos: demos,
              demo_strategy: demo_strategy,
              instructions_override: instructions_override
            }

            {:cont, {:ok, Map.put(acc, decl.name, state)}}

          {:error, exc} ->
            {:halt, {:error, exc}}
        end
      end)

    case result do
      {:ok, hydrated_predictors} ->
        prog = %{
          fresh
          | predictors: hydrated_predictors,
            metadata: hydrate_metadata(metadata_payload)
        }

        {:ok, prog}

      {:error, exc} ->
        {:error, exc}
    end
  end

  defp build_demos(demo_maps, input_names) when is_list(demo_maps) do
    Enum.map(demo_maps, &build_demo(&1, input_names))
  end

  defp build_demo(demo, input_names) do
    {kind_string, rest} = Map.pop(demo, "_kind", "labeled")
    data = Map.new(rest, &reatomize_key/1)
    example = Dsxir.Example.new(data, input_keys: input_names)

    case kind_string do
      "bootstrapped" -> %Dsxir.Demo{example: example, kind: :bootstrapped}
      _ -> %Dsxir.Demo{example: example, kind: :labeled}
    end
  end

  defp reatomize_key({k, v}) do
    case safe_existing_atom(k) do
      nil -> {k, v}
      atom -> {atom, v}
    end
  end

  defp hydrate_metadata(payload) when is_map(payload) do
    Map.new(payload, fn {k, v} -> {atom_or_keep(k), hydrate_metadata_value(k, v)} end)
  end

  defp atom_or_keep(name) do
    case safe_existing_atom(name) do
      nil -> name
      atom -> atom
    end
  end

  defp hydrate_metadata_value("compiled_with", value), do: optimizer_module(value)
  # `_miprov2_stats` falls through this clause: the encoded string-keyed map is
  # returned as-is and is **not** rehydrated into a `%Dsxir.Optimizer.MIPROv2.Stats{}`.
  # This asymmetry is intentional — see `encode_miprov2_stats/1` above.
  defp hydrate_metadata_value(_key, value), do: value

  defp optimizer_module(nil), do: nil

  defp optimizer_module(name) when is_binary(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError ->
      require Logger

      Logger.warning(
        "Dsxir.Artifact.load/3: optimizer module #{name} not loaded; metadata.compiled_with set to nil"
      )

      nil
  end

  defp decode_demo_strategy(nil, _input_names), do: {:ok, nil}

  defp decode_demo_strategy(%{"kind" => "knn"} = payload, input_names) do
    with {:ok, embedder} <- decode_embedder(Map.fetch!(payload, "embedder")),
         {:ok, embed_fields} <- decode_embed_fields(Map.fetch!(payload, "embed_fields")) do
      strategy = %KNN{
        k: Map.fetch!(payload, "k"),
        embedder: embedder,
        embedder_id: Map.fetch!(payload, "embedder_id"),
        embed_fields: embed_fields,
        entries: Enum.map(Map.get(payload, "entries", []), &decode_entry(&1, input_names))
      }

      {:ok, strategy}
    end
  end

  defp decode_demo_strategy(%{"kind" => other}, _input_names) do
    {:error,
     %Errors.Invalid.Configuration{
       key: :demo_strategy,
       value: other,
       reason: :unknown_kind
     }}
  end

  defp decode_embedder(%{"impl" => impl_string, "config" => config_map}) do
    impl = String.to_existing_atom(impl_string)

    case decode_embedder_config(config_map) do
      {:ok, kv} -> {:ok, {impl, kv}}
      {:error, exc} -> {:error, exc}
    end
  rescue
    ArgumentError ->
      {:error,
       %Errors.Invalid.Configuration{
         key: :embedder,
         value: impl_string,
         reason: :unknown_impl
       }}
  end

  defp decode_embedder_config(config_map) do
    Enum.reduce_while(config_map, {:ok, []}, fn {k, v}, {:ok, acc} ->
      case safe_existing_atom(k) do
        nil ->
          {:halt,
           {:error,
            %Errors.Invalid.Configuration{
              key: :embedder,
              value: k,
              reason: :unknown_config_key
            }}}

        atom ->
          {:cont, {:ok, [{atom, v} | acc]}}
      end
    end)
    |> case do
      {:ok, kv} -> {:ok, Enum.reverse(kv)}
      err -> err
    end
  end

  defp decode_embed_fields("all"), do: {:ok, :all}

  defp decode_embed_fields(fields) when is_list(fields) do
    Enum.reduce_while(fields, {:ok, []}, fn name, {:ok, acc} ->
      case safe_existing_atom(name) do
        nil ->
          {:halt,
           {:error,
            %Errors.Invalid.Configuration{
              key: :embed_fields,
              value: name,
              reason: :unknown_field
            }}}

        atom ->
          {:cont, {:ok, [atom | acc]}}
      end
    end)
    |> case do
      {:ok, atoms} -> {:ok, Enum.reverse(atoms)}
      err -> err
    end
  end

  defp decode_entry(%{"embedding" => embedding, "example" => example_data}, input_names) do
    data = Map.new(example_data, &reatomize_key/1)
    %Entry{embedding: embedding, example: Dsxir.Example.new(data, input_keys: input_names)}
  end
end
