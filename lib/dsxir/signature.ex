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
    with {:ok, compiled} <- Dsxir.Signature.Parser.parse(source) do
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

  defp apply_instruction(compiled, nil), do: compiled
  defp apply_instruction(compiled, instr), do: %{compiled | instruction: instr}
end
