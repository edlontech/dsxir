defmodule Dsxir.RuntimeProgram do
  @moduledoc """
  Pure-data runtime-authored program shape.

  `from_map/2` parses a JSON-ish payload, validates it semantically, runs the
  configured `program_plugs`, optionally persists to a store, and returns the
  finished `%RuntimeProgram{}`. Parse-only access is available through
  `parse/1` for callers that need pre-validation structural shape.

  ## Construction pipeline

  `from_map/2` runs four steps in order:

    1. parse the payload into typed structs (raises `Dsxir.Errors.Invalid.RuntimeProgram`
       on structural malformation),
    2. validate the parsed program (returns `{:error, %Invalid.RuntimeProgram{}}` on
       semantic failures),
    3. run `Dsxir.Settings.resolve(:program_plugs, [])` in declared order; the
       first plug returning `{:halt, reason}` raises `Dsxir.Errors.Halted.ProgramPlug`
       and prevents the rest from running,
    4. if a `:store` opt of the shape `{module, ref}` is supplied, call
       `module.put(ref, rp)`.

  The content-hash `:version` is computed on the validated program before plugs
  run so plug-side bookkeeping sees the final version.
  """

  alias Dsxir.Errors.Halted
  alias Dsxir.Errors.Invalid
  alias Dsxir.ProgramContext
  alias Dsxir.RuntimeProgram.Canonical
  alias Dsxir.RuntimeProgram.Edge
  alias Dsxir.RuntimeProgram.FieldSpec
  alias Dsxir.RuntimeProgram.Node
  alias Dsxir.RuntimeProgram.Validator
  alias Dsxir.Settings
  alias Dsxir.Signature.Compiled, as: SigCompiled

  @enforce_keys [:id, :version, :inputs, :outputs, :nodes, :edges]
  defstruct [:id, :version, :inputs, :outputs, :nodes, :edges, metadata: %{}]

  @type t :: %__MODULE__{
          id: String.t(),
          version: <<_::256>>,
          inputs: [FieldSpec.t()],
          outputs: [FieldSpec.t()],
          nodes: [Node.t()],
          edges: [Edge.t()],
          metadata: map()
        }

  @type from_map_opt ::
          {:store, {module(), term()}}
          | {:atoms, Dsxir.Signature.Parser.atom_mode()}

  @doc """
  Parse, validate, run `program_plugs`, and optionally persist a runtime
  program built from `payload`.

  Returns `{:ok, %RuntimeProgram{}}` on success, `{:error, %Dsxir.Errors.Invalid.RuntimeProgram{}}`
  on validation failure, and raises:

    * `Dsxir.Errors.Invalid.RuntimeProgram` on structural parse failure,
    * `Dsxir.Errors.Halted.ProgramPlug` if a `program_plug` returns `{:halt, reason}`.

  Accepts `atoms: :existing | :create` (default `:existing`), controlling how
  field names, node names, edge kinds, edge endpoints, node `opts` keys,
  signature-module names, and inline-signature field names in `payload` are
  turned into atoms. Only a trusted host should pass `atoms: :create`; a
  tenant-facing caller should keep the default so a crafted payload cannot
  mint unbounded atoms. The predictor `impl` string is always resolved with
  `String.to_existing_atom/1` regardless of `:atoms`, since it must name an
  already-loaded module; the semantic validator separately rejects a signature
  module that does not resolve to a loaded `Dsxir.Signature`. Raises
  `ArgumentError` for any other `:atoms` value.
  """
  @spec from_map(map(), [from_map_opt()]) ::
          {:ok, t()} | {:error, Invalid.RuntimeProgram.t()}
  def from_map(payload, opts \\ [])

  def from_map(%{} = payload, opts) when is_list(opts) do
    mode = fetch_atom_mode!(opts)

    with rp <- parse_payload(payload, mode),
         {:ok, validated} <- Validator.validate(rp),
         :ok <- run_program_plugs(validated, opts),
         :ok <- maybe_put_in_store(validated, opts) do
      {:ok, validated}
    end
  end

  @doc false
  @spec parse(map(), [{:atoms, Dsxir.Signature.Parser.atom_mode()}]) :: t()
  def parse(%{} = payload, opts \\ []) when is_list(opts) do
    parse_payload(payload, fetch_atom_mode!(opts))
  end

  defp fetch_atom_mode!(opts) do
    case Keyword.get(opts, :atoms, :existing) do
      mode when mode in [:existing, :create] ->
        mode

      other ->
        raise ArgumentError, "atoms: must be :existing or :create, got: #{inspect(other)}"
    end
  end

  @doc "Compute the SHA-256 content hash of the canonical encoding of `rp`."
  @spec version!(t()) :: <<_::256>>
  def version!(%__MODULE__{} = rp) do
    :crypto.hash(:sha256, Canonical.encode(rp))
  end

  defp parse_payload(%{} = payload, mode) do
    id = fetch_id!(payload)
    inputs = parse_fields(payload, "inputs", mode)
    outputs = parse_fields(payload, "outputs", mode)
    nodes = parse_nodes(payload, mode)
    edges = parse_edges(payload, mode)
    metadata = Map.get(payload, "metadata", %{})

    rp = %__MODULE__{
      id: id,
      version: <<0::256>>,
      inputs: inputs,
      outputs: outputs,
      nodes: nodes,
      edges: edges,
      metadata: metadata
    }

    %{rp | version: version!(rp)}
  end

  defp run_program_plugs(rp, opts) do
    context = ProgramContext.new(rp, opts)
    plugs = Settings.resolve(:program_plugs, [])
    run_plugs(plugs, context)
  end

  defp run_plugs([], _ctx), do: :ok

  defp run_plugs([plug | rest], ctx) when is_function(plug, 1) do
    case safe_invoke_plug(plug, ctx) do
      :ok ->
        run_plugs(rest, ctx)

      {:halt, reason} ->
        raise %Halted.ProgramPlug{plug: plug, reason: reason, context: ctx}
    end
  end

  defp run_plugs([bad | _], _ctx) do
    raise %Dsxir.Errors.Invalid.Configuration{
      key: :program_plugs,
      value: bad,
      reason: :not_a_1_arity_function
    }
  end

  defp safe_invoke_plug(plug, ctx) do
    plug.(ctx)
  rescue
    e -> {:halt, {:plug_exception, Exception.message(e)}}
  end

  defp maybe_put_in_store(rp, opts) do
    case Keyword.fetch(opts, :store) do
      :error -> :ok
      {:ok, {mod, ref}} -> mod.put(ref, rp)
    end
  end

  defp fetch_id!(%{"id" => id}) when is_binary(id), do: id

  defp fetch_id!(_),
    do: raise_parse_error("payload missing required string field \"id\"")

  defp parse_fields(payload, key, mode) do
    case Map.get(payload, key, []) do
      list when is_list(list) -> Enum.map(list, &parse_field(&1, key, mode))
      other -> raise_parse_error("#{inspect(key)} must be a list, got: #{inspect(other)}")
    end
  end

  defp parse_field(%{"name" => name, "type" => type} = field, _key, mode) when is_binary(name) do
    %FieldSpec{
      name: Dsxir.Signature.Parser.to_atom(name, mode),
      type: type,
      description: Map.get(field, "description")
    }
  end

  defp parse_field(other, key, _mode) do
    raise_parse_error("malformed field in #{inspect(key)}: #{inspect(other)}")
  end

  defp parse_nodes(%{"nodes" => nodes}, mode) when is_list(nodes) do
    Enum.map(nodes, &parse_node(&1, mode))
  end

  defp parse_nodes(%{"nodes" => other}, _mode) do
    raise_parse_error("\"nodes\" must be a list, got: #{inspect(other)}")
  end

  defp parse_nodes(_, _mode),
    do: raise_parse_error("payload missing required \"nodes\" list")

  defp parse_node(%{"name" => name, "impl" => impl, "signature" => signature} = node, mode)
       when is_binary(name) do
    %Node{
      name: Dsxir.Signature.Parser.to_atom(name, mode),
      impl: resolve_impl(impl),
      signature: parse_signature(signature, mode),
      guard: parse_guard(Map.get(node, "guard_source")),
      opts: parse_opts(Map.get(node, "opts"), mode)
    }
  end

  defp parse_node(other, _mode),
    do: raise_parse_error("malformed node entry: #{inspect(other)}")

  defp parse_opts(nil, _mode), do: []
  defp parse_opts(%{} = opts, mode), do: Enum.map(opts, &parse_opt_entry(&1, mode))

  defp parse_opts(other, _mode),
    do: raise_parse_error("\"opts\" must be a map, got: #{inspect(other)}")

  defp parse_opt_entry({key, value}, mode) when is_binary(key) do
    if json_scalar?(value) do
      {Dsxir.Signature.Parser.to_atom(key, mode), value}
    else
      raise_parse_error("opts.#{key} must be a JSON scalar value, got: #{inspect(value)}")
    end
  end

  defp parse_opt_entry({key, _value}, _mode),
    do: raise_parse_error("opts keys must be strings, got: #{inspect(key)}")

  defp json_scalar?(v), do: is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v)

  defp parse_edges(%{"edges" => edges}, mode) when is_list(edges) do
    Enum.map(edges, &parse_edge(&1, mode))
  end

  defp parse_edges(%{"edges" => other}, _mode) do
    raise_parse_error("\"edges\" must be a list, got: #{inspect(other)}")
  end

  defp parse_edges(_, _mode),
    do: raise_parse_error("payload missing required \"edges\" list")

  defp parse_edge(%{"from" => from, "to" => to} = edge, mode) do
    kind = edge |> Map.get("kind", "required") |> Dsxir.Signature.Parser.to_atom(mode)
    %Edge{from: parse_edge_endpoint(from, mode), to: parse_edge_endpoint(to, mode), kind: kind}
  end

  defp parse_edge(other, _mode),
    do: raise_parse_error("malformed edge entry: #{inspect(other)}")

  defp parse_edge_endpoint(["program_input", field], mode) when is_binary(field),
    do: {:program_input, Dsxir.Signature.Parser.to_atom(field, mode)}

  defp parse_edge_endpoint(["program_output", field], mode) when is_binary(field),
    do: {:program_output, Dsxir.Signature.Parser.to_atom(field, mode)}

  defp parse_edge_endpoint(["node", node, field], mode) when is_binary(node) and is_binary(field),
    do:
      {:node, Dsxir.Signature.Parser.to_atom(node, mode),
       Dsxir.Signature.Parser.to_atom(field, mode)}

  defp parse_edge_endpoint(["const", value], _mode), do: {:const, value}

  defp parse_edge_endpoint(other, _mode),
    do: raise_parse_error("invalid edge endpoint: #{inspect(other)}")

  defp resolve_impl(name) when is_binary(name), do: String.to_existing_atom(name)

  defp resolve_impl(other),
    do: raise_parse_error("node impl must be a module-atom string, got: #{inspect(other)}")

  defp parse_signature(name, mode) when is_binary(name),
    do: Dsxir.Signature.Parser.to_atom(name, mode)

  defp parse_signature(%{} = inline, mode),
    do: Dsxir.Signature.from_inline_blob(inline, atoms: mode)

  defp parse_signature(other, _mode),
    do:
      raise_parse_error(
        "node signature must be a module-atom string or inline blob, got: #{inspect(other)}"
      )

  defp parse_guard(nil), do: nil

  defp parse_guard(source) when is_binary(source),
    do: %Dsxir.Predicate.Source{source: source}

  defp parse_guard(other),
    do: raise_parse_error("guard_source must be a string or nil, got: #{inspect(other)}")

  defp raise_parse_error(message) do
    raise %Invalid.RuntimeProgram{
      errors: [%{path: [], code: :parse_error, message: message, suggestion: nil}]
    }
  end

  @doc """
  Serialize `rp` to a JSON-safe map suitable for embedding in a v2 artifact
  envelope. The inverse is `from_artifact_blob/1`.

  Predicate ASTs are intentionally dropped — only `:source` strings survive a
  round-trip so re-validation always re-parses from the canonical source.
  """
  @spec to_artifact_blob(t()) :: map()
  def to_artifact_blob(%__MODULE__{} = rp) do
    %{
      "id" => rp.id,
      "version" => Base.encode16(rp.version, case: :lower),
      "inputs" => Enum.map(rp.inputs, &encode_field/1),
      "outputs" => Enum.map(rp.outputs, &encode_field/1),
      "nodes" => Enum.map(rp.nodes, &encode_node/1),
      "edges" => Enum.map(rp.edges, &encode_edge/1),
      "metadata" => rp.metadata
    }
  end

  @doc """
  Reconstruct a `%RuntimeProgram{}` from a JSON-decoded artifact blob,
  re-running `Validator.validate/1` so predicate sources are re-parsed and
  type-checked. Raises `Dsxir.Errors.Invalid.RuntimeProgram` if the program
  fails to validate, including when the blob's claimed `version` does not
  match the recomputed canonical hash. `program_plugs` are **not** run on
  load.
  """
  @spec from_artifact_blob(map()) :: t()
  def from_artifact_blob(%{} = blob) do
    rp = parse_artifact_blob(blob)
    :ok = verify_version!(rp)

    case Validator.validate(rp) do
      {:ok, validated} -> validated
      {:error, %Invalid.RuntimeProgram{} = exc} -> raise exc
    end
  end

  defp verify_version!(%__MODULE__{version: claimed} = rp) do
    recomputed = version!(%{rp | version: <<0::256>>})

    if recomputed == claimed do
      :ok
    else
      raise %Invalid.RuntimeProgram{
        errors: [
          %{
            path: [:version],
            code: :version_mismatch,
            message:
              "artifact version hex does not match the recomputed canonical hash; " <>
                "claimed=#{Base.encode16(claimed, case: :lower)} " <>
                "recomputed=#{Base.encode16(recomputed, case: :lower)}",
            suggestion: nil
          }
        ]
      }
    end
  end

  defp encode_field(%FieldSpec{name: name, type: type, description: desc}) do
    base = %{"name" => Atom.to_string(name), "type" => encode_type(type)}
    if desc, do: Map.put(base, "description", desc), else: base
  end

  defp encode_type(type) when is_binary(type), do: type
  defp encode_type(type) when is_atom(type), do: Atom.to_string(type)
  defp encode_type({:list, inner}), do: "list[" <> encode_type(inner) <> "]"
  defp encode_type(other), do: inspect(other)

  defp encode_node(%Node{name: name, impl: impl, signature: sig, guard: guard, opts: opts}) do
    base = %{
      "name" => Atom.to_string(name),
      "impl" => Atom.to_string(impl),
      "signature" => encode_signature(sig)
    }

    base =
      case guard do
        nil -> base
        %Dsxir.Predicate.Source{source: src} -> Map.put(base, "guard_source", src)
      end

    if opts == [] do
      base
    else
      Map.put(base, "opts", Map.new(opts, fn {k, v} -> {Atom.to_string(k), v} end))
    end
  end

  defp encode_signature(mod) when is_atom(mod), do: Atom.to_string(mod)

  defp encode_signature(%SigCompiled{} = sig) do
    case sig.source do
      {:inline, blob} -> blob
      _ -> compiled_to_inline_blob(sig)
    end
  end

  defp compiled_to_inline_blob(%SigCompiled{fields: fields, instruction: instr}) do
    %{
      "instruction" => instr,
      "fields" => Enum.map(fields, &field_to_blob/1)
    }
  end

  defp field_to_blob(field) do
    base = %{
      "name" => Atom.to_string(field.name),
      "type" => encode_type(field.type),
      "kind" => Atom.to_string(field.kind)
    }

    if field.desc, do: Map.put(base, "desc", field.desc), else: base
  end

  defp encode_edge(%Edge{from: from, to: to, kind: kind}) do
    %{
      "from" => encode_endpoint(from),
      "to" => encode_endpoint(to),
      "kind" => Atom.to_string(kind)
    }
  end

  defp encode_endpoint({:program_input, field}),
    do: ["program_input", Atom.to_string(field)]

  defp encode_endpoint({:program_output, field}),
    do: ["program_output", Atom.to_string(field)]

  defp encode_endpoint({:node, name, field}),
    do: ["node", Atom.to_string(name), Atom.to_string(field)]

  defp encode_endpoint({:const, value}), do: ["const", value]

  defp parse_artifact_blob(%{"id" => id} = blob) when is_binary(id) do
    inputs = parse_fields(blob, "inputs", :existing)
    outputs = parse_fields(blob, "outputs", :existing)
    nodes = parse_nodes(blob, :existing)
    edges = parse_edges(blob, :existing)
    metadata = Map.get(blob, "metadata", %{})
    version = decode_version(Map.get(blob, "version"))

    %__MODULE__{
      id: id,
      version: version,
      inputs: inputs,
      outputs: outputs,
      nodes: nodes,
      edges: edges,
      metadata: metadata
    }
  end

  defp parse_artifact_blob(_),
    do: raise_parse_error("artifact blob missing required string field \"id\"")

  defp decode_version(nil), do: <<0::256>>

  defp decode_version(hex) when is_binary(hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, <<_::256>> = bin} -> bin
      _ -> raise_parse_error("invalid version: expected 64-hex-character SHA-256")
    end
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%Dsxir.RuntimeProgram{} = rp, _opts) do
      concat([
        "#Dsxir.RuntimeProgram<id: ",
        inspect(rp.id),
        ", version: ",
        Dsxir.RuntimeProgram.short_version(rp.version),
        ", nodes: ",
        Integer.to_string(length(rp.nodes)),
        ", edges: ",
        Integer.to_string(length(rp.edges)),
        ">"
      ])
    end
  end

  @doc false
  @spec short_version(binary()) :: String.t()
  def short_version(<<_::256>> = bin),
    do: bin |> Base.encode16(case: :lower) |> binary_part(0, 8)

  def short_version(_), do: "<unset>"
end
