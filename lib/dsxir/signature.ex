defmodule Dsxir.Signature do
  @moduledoc """
  Declarative signature module. Wraps `Spark.Dsl` so authors write:

      defmodule MyApp.AnswerQuestion do
        use Dsxir.Signature

        signature do
          instruction "Answer the user's question."
          input :question, :string
          output :answer, :string, desc: "A direct factual answer."
        end
      end

  Inline string-form signatures are also supported via `from_string/2` and may
  be passed directly to the Module DSL `predictor` entity:

      predictor :answer, Dsxir.Predictor.Predict, signature: "question -> answer"

  The grammar mirrors DSPy's: `inputs -> outputs` with optional `name: type`
  annotations.
  """

  use Spark.Dsl, default_extensions: [extensions: [Dsxir.Signature.Dsl]]

  alias Dsxir.Signature.Compiled

  @doc """
  Compile a string-form signature into a `Dsxir.Signature.Compiled{}`.

  Returns `{:ok, compiled}` on success or `{:error, reason}` on parse failure.
  Use `from_string!/2` for the raising variant.
  """
  @spec from_string(String.t(), keyword()) :: {:ok, Compiled.t()} | {:error, term()}
  def from_string(source, opts \\ []) when is_binary(source) and is_list(opts) do
    with {:ok, compiled} <- Dsxir.Signature.Parser.parse(source, Keyword.take(opts, [:atoms])) do
      {:ok, apply_instruction(compiled, Keyword.get(opts, :instruction))}
    end
  end

  @doc """
  Compile a string-form signature, raising `Dsxir.Errors.Invalid.Signature` on
  parse failure.
  """
  @spec from_string!(String.t(), keyword()) :: Compiled.t()
  def from_string!(source, opts \\ []) when is_binary(source) and is_list(opts) do
    case from_string(source, opts) do
      {:ok, compiled} ->
        compiled

      {:error, reason} ->
        raise %Dsxir.Errors.Invalid.Signature{
          module: Keyword.get(opts, :module),
          field: nil,
          reason: reason
        }
    end
  end

  @doc """
  Build a `Dsxir.Signature.Compiled` from an inline JSON-ish blob carrying a
  list of `"fields"` and an optional `"instruction"`. Each field map carries
  `"name"`, `"type"` (string in the same grammar as `from_string/2`), `"kind"`
  (`"input"` or `"output"`), and an optional `"desc"`. Used by
  `Dsxir.RuntimeProgram.from_map/2` when a runtime payload inlines its
  signature rather than naming a module.

  Reuses `from_string!/2` by reconstructing the equivalent `inputs -> outputs`
  string from the blob's fields, then attaching `desc` and an `{:inline, blob}`
  source tag.

  Accepts `atoms: :existing | :create` (default `:existing`). Because the blob
  is normally untrusted serialized input, field names are by default resolved
  with `String.to_existing_atom/1`: an unknown name fails the parse rather
  than minting an atom, so a crafted payload cannot exhaust the atom table.
  This matches the existing-atom discipline the rest of
  `Dsxir.RuntimeProgram` deserialization already follows. Pass `atoms: :create`
  only for a trusted host willing to mint atoms from the payload.
  """
  @spec from_inline_blob(map(), [{:atoms, Dsxir.Signature.Parser.atom_mode()}]) :: Compiled.t()
  def from_inline_blob(blob, opts \\ [])

  def from_inline_blob(%{"fields" => fields} = blob, opts) when is_list(fields) do
    mode = Keyword.get(opts, :atoms, :existing)

    {inputs, outputs} =
      Enum.split_with(fields, fn %{"kind" => k} -> k == "input" end)

    source =
      Enum.map_join(inputs, ", ", &inline_field_to_source/1) <>
        " -> " <>
        Enum.map_join(outputs, ", ", &inline_field_to_source/1)

    compiled =
      from_string!(source, instruction: Map.get(blob, "instruction"), atoms: mode)

    by_name = Map.new(fields, fn %{"name" => n} = f -> {n, f} end)

    updated_fields =
      Enum.map(compiled.fields, fn field ->
        case Map.fetch(by_name, Atom.to_string(field.name)) do
          {:ok, blob_field} -> %{field | desc: Map.get(blob_field, "desc")}
          :error -> field
        end
      end)

    %{compiled | fields: updated_fields, source: {:inline, blob}}
  end

  defp inline_field_to_source(%{"name" => name, "type" => type})
       when is_binary(name) and is_binary(type) do
    name <> ":" <> type
  end

  defp apply_instruction(compiled, nil), do: compiled
  defp apply_instruction(compiled, instr), do: %{compiled | instruction: instr}
end
