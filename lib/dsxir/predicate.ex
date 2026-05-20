defmodule Dsxir.Predicate do
  @moduledoc """
  Bounded expression DSL for runtime predicates.

  Grammar (see `Dsxir.Predicate.Parser` for the full productions):

    * literals: integer, float, string (double-quoted), atom (`:foo`),
      boolean (`true`/`false`), nil
    * field reference: `namespace.field_name`; `input.field_name` is a
      shortcut for the program input namespace
    * `length(field)` — applies to strings or lists
    * comparisons: `==`, `!=`, `<`, `<=`, `>`, `>=`, `in`, `not in`
    * boolean composition: `and`, `or`, `not`, parentheses
    * arithmetic on the RHS of a comparison is literal-only and folded
      at parse time

  No runtime function calls, no string operations, no map indexing.

  All identifier atoms are resolved through `String.to_existing_atom/1`.
  An unknown atom yields `{:error, %{code: :predicate_parse_error}}` —
  dynamic atom creation from input is prohibited.
  """

  alias Dsxir.Predicate.AST
  alias Dsxir.Predicate.Evaluator
  alias Dsxir.Predicate.Parser
  alias Dsxir.Predicate.TypeChecker

  @doc """
  Parses a predicate source string.

  Returns `{:ok, %AST{}}` on success. On failure returns
  `{:error, %{code: :predicate_parse_error, message: _, line: _, col: _}}`.
  """
  @spec parse(String.t()) :: {:ok, AST.t()} | {:error, map()}
  def parse(source) when is_binary(source) do
    case Parser.predicate(source) do
      {:ok, [expr], "", _ctx, _line, _col} ->
        {:ok, %AST{expr: expr, source: source}}

      {:ok, _stack, rest, _ctx, {line, _line_start}, col} ->
        {:error,
         %{
           code: :predicate_parse_error,
           message: "unexpected input",
           line: line,
           col: col,
           remaining: rest
         }}

      {:error, reason, rest, _ctx, {line, _line_start}, col} ->
        {:error,
         %{
           code: :predicate_parse_error,
           message: reason,
           line: line,
           col: col,
           remaining: rest
         }}
    end
  end

  @doc """
  Type-checks an AST against `env`. The root expression must be boolean.
  """
  @spec type_check(AST.t(), TypeChecker.env()) :: :ok | {:error, map()}
  def type_check(%AST{} = ast, env), do: TypeChecker.check(ast.expr, env)

  @doc """
  Evaluates an AST against a runtime `env`.

  `env` is `%{namespace_atom => %{field_atom => runtime_value}}`. The
  special namespace `:program_input` holds the program's input values.
  """
  @spec eval(AST.t(), Evaluator.env()) :: {:ok, boolean()} | {:error, map()}
  def eval(%AST{} = ast, env), do: Evaluator.eval(ast.expr, env)

  @doc """
  Returns the original source string used to build the AST. Round-trips
  back to an equivalent AST modulo constant folding.
  """
  @spec format(AST.t()) :: String.t()
  def format(%AST{source: source}), do: source
end
