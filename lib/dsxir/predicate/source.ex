defmodule Dsxir.Predicate.Source do
  @moduledoc """
  Holds a predicate source string. The parsed AST is attached later by the
  predicate parser; until then `ast:` stays `nil`. Hashing uses only the
  `:source` field, so attaching an AST never changes a program's version.
  """

  @enforce_keys [:source]
  defstruct [:source, ast: nil]

  @type t :: %__MODULE__{source: String.t(), ast: nil | Dsxir.Predicate.AST.t()}

  @doc "Attach a parsed AST to a `%Source{}`. Used by the Validator post-parse."
  @spec attach_ast(t(), Dsxir.Predicate.AST.t()) :: t()
  def attach_ast(%__MODULE__{} = src, %Dsxir.Predicate.AST{} = ast),
    do: %{src | ast: ast}
end
