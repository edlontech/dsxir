defmodule Dsxir.Artifact do
  @moduledoc """
  Encode and decode `Dsxir.Program` save/load artifacts.

  The on-disk JSON envelope (format_version "2"):

      {
        "format_version": "2",
        "source_kind": "module" | "runtime",
        "source": <blob>,
        "predictors": {"<name>": {"instructions": ..., "demos": [...]}, ...},
        "metadata": {"compiled_with": ..., "score": ..., "trainset_hash": ...}
      }

  For `source_kind: "module"`, `source` is the user-module atom name (e.g.
  `"Elixir.MyApp.QA"`). For `source_kind: "runtime"`, `source` is a JSON-safe
  serialization of the wrapped `%Dsxir.RuntimeProgram{}` carrying guard
  *sources* only — never parsed ASTs. On load the runtime program is
  re-validated end-to-end so guard sources are re-parsed and type-checked.

  `encode/1` always emits format_version "2"; saving as v1 is unsupported.
  `decode/2` and `decode_and_hydrate/2` upgrade v1 (legacy unwrapped
  per-predictor maps) on the fly by inferring `source_kind: "module"`.
  """

  alias Dsxir.DemoStrategy.KNN
  alias Dsxir.DemoStrategy.KNN.Entry
  alias Dsxir.Errors
  alias Dsxir.Module.Info, as: ModuleInfo
  alias Dsxir.Program
  alias Dsxir.Program.Source
  alias Dsxir.Signature.Runtime, as: SignatureRuntime

  @reserved_metadata_key "_metadata"
  @format_version "2"

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
  def encode(%Program{source: source, predictors: predictors, metadata: metadata}) do
    {kind, blob} = encode_source(source)

    %{
      "format_version" => @format_version,
      "source_kind" => kind,
      "source" => blob,
      "predictors" => encode_predictors(source, predictors),
      "metadata" => encode_metadata(metadata)
    }
  end

  defp encode_source(%Source.Module{} = src), do: {"module", Source.to_artifact_blob(src)}

  defp encode_source(%Source.RuntimeProgram{} = src),
    do: {"runtime", Source.to_artifact_blob(src)}

  defp encode_predictors(%Source.Module{module: mod}, predictors) do
    Map.new(ModuleInfo.module(mod), fn decl ->
      state = Map.get(predictors, decl.name, %Program.State{})
      {Atom.to_string(decl.name), encode_predictor(state, decl.signature)}
    end)
  end

  defp encode_predictors(%Source.RuntimeProgram{runtime_program: rp}, predictors) do
    Map.new(rp.nodes, fn node ->
      state = Map.get(predictors, node.name, %Program.State{})
      {Atom.to_string(node.name), encode_predictor(state, node.signature)}
    end)
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

  Accepts v1 (legacy, per-predictor top-level map) and v2 envelopes. For v2
  module-source envelopes the on-disk module name must match `target_module`.
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
  Decode a v2 envelope (or v1, upgrading on the fly) directly from a JSON
  string into a `%Program{}`. Raises on validation failure or on a malformed
  envelope.

  Pass `:target_module` to disambiguate a v1 legacy payload that does not
  carry its source identity inline. Without `:target_module`, v1 payloads
  raise `Dsxir.Errors.Invalid.Configuration`.
  """
  @spec decode_and_hydrate(String.t() | map(), keyword()) :: Program.t()
  def decode_and_hydrate(json_or_map, opts \\ [])

  def decode_and_hydrate(json, opts) when is_binary(json) do
    decode_and_hydrate(Jason.decode!(json), opts)
  end

  def decode_and_hydrate(%{"format_version" => "2"} = blob, _opts) do
    case hydrate_v2(blob) do
      {:ok, prog} -> prog
      {:error, exc} -> raise exc
    end
  end

  def decode_and_hydrate(%{} = legacy, opts) do
    case Keyword.fetch(opts, :target_module) do
      {:ok, mod} when is_atom(mod) ->
        case decode(mod, legacy) do
          {:ok, prog} -> prog
          {:error, exc} -> raise exc
        end

      :error ->
        raise %Errors.Invalid.Configuration{
          key: :target_module,
          value: nil,
          reason: :v1_artifact_requires_target_module
        }
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
  def decode(target_module, %{"format_version" => "2"} = envelope) when is_atom(target_module) do
    decode_v2_into_target(target_module, envelope)
  end

  def decode(target_module, decoded) when is_atom(target_module) and is_map(decoded) do
    decode_v1(target_module, decoded)
  end

  defp decode_v2_into_target(_target_module, %{"source_kind" => "runtime"} = envelope) do
    hydrate_v2(envelope)
  end

  defp decode_v2_into_target(target_module, %{"source_kind" => "module"} = envelope) do
    with {:ok, on_disk_source} <- decode_on_disk_module_source(envelope),
         :ok <- ensure_target_module_matches(target_module, on_disk_source.module) do
      decls = ModuleInfo.module(target_module)
      expected = expected_shape(decls)
      predictors_payload = Map.get(envelope, "predictors", %{})
      metadata_payload = Map.get(envelope, "metadata", %{})
      loaded = Map.new(predictors_payload, fn {name, body} -> {name, demo_keys_in(body)} end)

      case structural_diff(expected, loaded) do
        %{missing_predictors: [], extra_predictors: [], field_diffs: empty} when empty == %{} ->
          hydrate_with_source(on_disk_source, decls, predictors_payload, metadata_payload)

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
  end

  defp decode_v2_into_target(_target_module, envelope), do: hydrate_v2(envelope)

  defp decode_on_disk_module_source(%{"source" => mod_str}) when is_binary(mod_str) do
    {:ok, Source.Module.from_artifact_blob(mod_str)}
  rescue
    ArgumentError ->
      {:error,
       %Errors.Invalid.Configuration{
         key: :source,
         value: mod_str,
         reason: :module_not_loaded
       }}
  end

  defp decode_on_disk_module_source(envelope) do
    {:error,
     %Errors.Invalid.Configuration{
       key: :source,
       value: Map.get(envelope, "source"),
       reason: :unknown_or_missing
     }}
  end

  defp ensure_target_module_matches(target, target), do: :ok

  defp ensure_target_module_matches(target, on_disk) do
    {:error,
     %Errors.Invalid.Configuration{
       key: :target_module,
       value: %{target: target, on_disk: on_disk},
       reason: :module_mismatch
     }}
  end

  defp decode_v1(target_module, decoded) do
    decls = ModuleInfo.module(target_module)
    expected = expected_shape(decls)
    {metadata_payload, predictors_payload} = Map.pop(decoded, @reserved_metadata_key, %{})
    loaded = Map.new(predictors_payload, fn {name, body} -> {name, demo_keys_in(body)} end)

    case structural_diff(expected, loaded) do
      %{missing_predictors: [], extra_predictors: [], field_diffs: empty} when empty == %{} ->
        source = Source.Module.new!(target_module)
        hydrate_with_source(source, decls, predictors_payload, metadata_payload)

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

  defp hydrate_v2(%{"source_kind" => "module", "source" => mod_str} = envelope)
       when is_binary(mod_str) do
    source = Source.Module.from_artifact_blob(mod_str)
    decls = ModuleInfo.module(source.module)
    predictors_payload = Map.get(envelope, "predictors", %{})
    metadata_payload = Map.get(envelope, "metadata", %{})
    hydrate_with_source(source, decls, predictors_payload, metadata_payload)
  rescue
    ArgumentError ->
      {:error,
       %Errors.Invalid.Configuration{
         key: :source,
         value: envelope["source"],
         reason: :module_not_loaded
       }}
  end

  defp hydrate_v2(%{"source_kind" => "runtime", "source" => blob} = envelope)
       when is_map(blob) do
    source = Dsxir.Program.Source.RuntimeProgram.from_artifact_blob(blob)
    decls = Source.predictors(source)
    predictors_payload = Map.get(envelope, "predictors", %{})
    metadata_payload = Map.get(envelope, "metadata", %{})
    hydrate_with_source(source, decls, predictors_payload, metadata_payload)
  rescue
    ArgumentError ->
      {:error,
       %Errors.Invalid.Configuration{
         key: :source,
         value: envelope["source"],
         reason: :atom_not_loaded
       }}
  end

  defp hydrate_v2(envelope) do
    {:error,
     %Errors.Invalid.Configuration{
       key: :source_kind,
       value: Map.get(envelope, "source_kind"),
       reason: :unknown_or_missing
     }}
  end

  defp hydrate_with_source(source, decls, predictors_payload, metadata_payload) do
    fresh = Program.new(source, Enum.map(decls, & &1.name))

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
