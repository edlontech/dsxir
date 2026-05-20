defmodule Dsxir.Predicate.AST do
  @moduledoc """
  Parsed predicate tree.

  `expr` is a tagged-tuple AST; `source` is the original predicate string
  the parser was given. The AST is intentionally minimal — see
  `Dsxir.Predicate.Parser` for the productions that build it.
  """

  @enforce_keys [:expr, :source]
  defstruct [:expr, :source]

  @type type :: :boolean | :integer | :float | :string | :atom | :any
  @type lit :: {:lit, term()}
  @type lit_list :: {:lit_list, [term()]}
  @type field :: {:field, atom(), atom()} | {:program_input, atom()}
  @type length_expr :: {:length, field()}
  @type comp_op :: :eq | :neq | :lt | :lte | :gt | :gte | :in | :not_in
  @type comp :: {comp_op(), field() | length_expr(), lit() | lit_list()}
  @type bool_expr :: {:and, [t_expr()]} | {:or, [t_expr()]} | {:not, t_expr()}
  @type t_expr :: comp() | bool_expr() | lit()
  @type t :: %__MODULE__{expr: t_expr(), source: String.t()}

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%Dsxir.Predicate.AST{source: source}, _opts) do
      concat(["#Dsxir.Predicate.AST<", inspect(source), ">"])
    end
  end
end
