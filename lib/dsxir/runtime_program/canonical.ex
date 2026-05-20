defmodule Dsxir.RuntimeProgram.Canonical do
  @moduledoc """
  Canonical IO-list encoding of a `Dsxir.RuntimeProgram` used as the input to
  the SHA-256 content hash that becomes the program's `:version`.

  Determinism rules:

    * Map keys are sorted alphabetically before being encoded.
    * Atoms are encoded as binaries to avoid coupling to the BEAM atom table.
    * Tuples are encoded as `["__tuple__", elems...]`.
    * Non-semantic fields are excluded — `description` on `FieldSpec` and on the
      program's `metadata`. Other metadata is included.
    * Node and edge order is significant and is preserved verbatim.
    * Predicate strings are encoded verbatim; the parsed AST is not part of
      the hash.
    * Inline `Dsxir.Signature.Compiled` structs are encoded by their fields
      list plus `:instruction`. Module-atom signatures are encoded by their
      fully-qualified atom name.
    * Strings escape `"` as `\\\"`.
  """

  alias Dsxir.RuntimeProgram
  alias Dsxir.RuntimeProgram.Edge
  alias Dsxir.RuntimeProgram.FieldSpec
  alias Dsxir.RuntimeProgram.Node
  alias Dsxir.Signature.Compiled

  @doc """
  Encode `rp` deterministically as an iolist suitable for SHA-256 hashing.

  Same logical content always produces the same bytes; see the rules in this
  module's `@moduledoc`.
  """
  @spec encode(RuntimeProgram.t()) :: iodata()
  def encode(%RuntimeProgram{} = rp) do
    [
      "rp:",
      encode_term(rp.id),
      "|in:",
      encode_list(rp.inputs, &encode_field_for_hash/1),
      "|out:",
      encode_list(rp.outputs, &encode_field_for_hash/1),
      "|nodes:",
      encode_list(rp.nodes, &encode_node/1),
      "|edges:",
      encode_list(rp.edges, &encode_edge/1),
      "|meta:",
      encode_map(strip_description(rp.metadata))
    ]
  end

  @doc false
  @spec encode_term_for_test(term()) :: iodata()
  def encode_term_for_test(term), do: encode_term(term)

  defp encode_field_for_hash(%FieldSpec{name: name, type: type}) do
    encode_map(%{"name" => name, "type" => type})
  end

  defp encode_node(%Node{} = n) do
    encode_map(%{
      "name" => n.name,
      "impl" => n.impl,
      "signature" => encode_signature(n.signature),
      "guard" => encode_guard(n.guard)
    })
  end

  defp encode_edge(%Edge{from: from, to: to, kind: kind}) do
    encode_map(%{"from" => from, "to" => to, "kind" => kind})
  end

  defp encode_signature(mod) when is_atom(mod), do: Atom.to_string(mod)

  defp encode_signature(%Compiled{fields: fields, instruction: instruction}) do
    %{
      "fields" => Enum.map(fields, &field_for_hash/1),
      "instruction" => instruction
    }
  end

  defp field_for_hash(field) do
    %{
      "name" => field.name,
      "type" => field.type,
      "kind" => field.kind
    }
  end

  defp encode_guard(nil), do: nil
  defp encode_guard(%Dsxir.Predicate.Source{source: source}), do: source

  defp strip_description(metadata) when is_map(metadata) do
    Map.drop(metadata, ["description", :description])
  end

  defp encode_list(list, fun) when is_list(list) do
    [?[, Enum.map_intersperse(list, ?,, fun), ?]]
  end

  defp encode_map(map) when is_map(map) do
    pairs =
      map
      |> Enum.map(fn {k, v} -> {to_string(k), encode_term(v)} end)
      |> Enum.sort_by(fn {k, _} -> k end)

    [?{, Enum.map_intersperse(pairs, ?,, &encode_pair/1), ?}]
  end

  defp encode_pair({k, v}), do: [encode_string(k), ?:, v]

  defp encode_term(nil), do: "null"
  defp encode_term(true), do: "true"
  defp encode_term(false), do: "false"
  defp encode_term(v) when is_binary(v), do: encode_string(v)
  defp encode_term(v) when is_atom(v), do: encode_string(Atom.to_string(v))
  defp encode_term(v) when is_integer(v), do: Integer.to_string(v)
  defp encode_term(v) when is_float(v), do: Float.to_string(v)
  defp encode_term(v) when is_list(v), do: encode_list(v, &encode_term/1)

  defp encode_term(v) when is_tuple(v) do
    encode_list(["__tuple__" | Tuple.to_list(v)], &encode_term/1)
  end

  defp encode_term(%Compiled{} = c), do: encode_map(encode_signature(c))
  defp encode_term(%Dsxir.Predicate.Source{source: source}), do: encode_string(source)

  defp encode_term(%mod{} = struct) do
    struct
    |> Map.from_struct()
    |> Map.put("__struct__", Atom.to_string(mod))
    |> encode_map()
  end

  defp encode_term(%{} = v), do: encode_map(v)

  defp encode_string(bin) when is_binary(bin) do
    [?", :binary.replace(bin, "\"", "\\\"", [:global]), ?"]
  end
end
