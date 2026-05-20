defmodule Dsxir.Predicate.Parser do
  @moduledoc """
  NimbleParsec grammar for the predicate DSL.

  Productions:

      literal   ::= int | float | string | atom | bool | nil
      field     ::= identifier "." identifier             (input.foo -> program_input)
      length    ::= "length" "(" field ")"
      comp_lhs  ::= field | length
      comp_rhs  ::= literal | "[" literal ("," literal)* "]" | folded_arith
      compare   ::= comp_lhs op comp_rhs
      expr      ::= or_expr
      or_expr   ::= and_expr ("or" and_expr)*
      and_expr  ::= not_expr ("and" not_expr)*
      not_expr  ::= "not" not_expr | atom_expr
      atom_expr ::= compare | "(" expr ")"

  Identifier atoms are resolved via `String.to_existing_atom/1`. Unknown
  atoms raise a `:predicate_parse_error`.

  Arithmetic on the comparison RHS is literal-only and folded at parse
  time. Any non-literal in the arithmetic sub-tree raises a parse error.
  """

  import NimbleParsec

  @reserved ~w(and or not in nil true false length)

  whitespace = ascii_string([?\s, ?\t, ?\n, ?\r], min: 1) |> ignore()
  ws = optional(whitespace)

  digits = ascii_string([?0..?9], min: 1)
  sign = ascii_string([?-], 1)

  int =
    optional(sign)
    |> concat(digits)
    |> reduce({Enum, :join, [""]})
    |> map({String, :to_integer, []})

  float =
    optional(sign)
    |> concat(digits)
    |> string(".")
    |> concat(digits)
    |> reduce({Enum, :join, [""]})
    |> map({String, :to_float, []})

  # ---- string literal ----------------------------------------------------

  string_char =
    choice([
      string("\\\"") |> replace(?"),
      string("\\\\") |> replace(?\\),
      string("\\n") |> replace(?\n),
      string("\\t") |> replace(?\t),
      string("\\r") |> replace(?\r),
      utf8_char(not: ?")
    ])

  string_literal =
    ignore(string("\""))
    |> repeat(string_char)
    |> ignore(string("\""))
    |> reduce({List, :to_string, []})

  # ---- identifiers -------------------------------------------------------

  ident_start = ascii_char([?a..?z, ?A..?Z, ?_])
  ident_cont = ascii_char([?a..?z, ?A..?Z, ?0..?9, ?_])

  raw_ident =
    ident_start
    |> repeat(ident_cont)
    |> reduce({List, :to_string, []})

  identifier =
    raw_ident
    |> post_traverse({__MODULE__, :__check_not_reserved__, []})

  # ---- atom literal :foo -------------------------------------------------

  atom_literal =
    ignore(string(":"))
    |> concat(raw_ident)
    |> post_traverse({__MODULE__, :__to_atom_value__, []})

  # ---- boolean / nil -----------------------------------------------------

  bool_lit =
    choice([
      string("true") |> replace(true),
      string("false") |> replace(false)
    ])
    |> post_traverse({__MODULE__, :__wrap_value__, []})

  nil_lit =
    string("nil")
    |> replace(nil)
    |> post_traverse({__MODULE__, :__wrap_value__, []})

  # ---- field / length ----------------------------------------------------

  field =
    identifier
    |> ignore(string("."))
    |> concat(identifier)
    |> post_traverse({__MODULE__, :__field__, []})

  length_expr =
    ignore(string("length"))
    |> concat(ws)
    |> ignore(string("("))
    |> concat(ws)
    |> concat(field)
    |> concat(ws)
    |> ignore(string(")"))
    |> post_traverse({__MODULE__, :__length__, []})

  comp_lhs = choice([length_expr, field])

  # ---- literal -----------------------------------------------------------
  # Each literal pushes a single `{:val, term}` on the stack.

  literal =
    choice([
      float |> post_traverse({__MODULE__, :__wrap_value__, []}),
      int |> post_traverse({__MODULE__, :__wrap_value__, []}),
      string_literal |> post_traverse({__MODULE__, :__wrap_value__, []}),
      atom_literal,
      bool_lit,
      nil_lit
    ])

  # ---- arithmetic (RHS only, folded at parse) ---------------------------

  defcombinatorp(
    :arith_factor,
    choice([
      ignore(string("("))
      |> concat(ws)
      |> parsec(:arith_expr)
      |> concat(ws)
      |> ignore(string(")")),
      literal,
      field |> post_traverse({__MODULE__, :__arith_non_literal__, []})
    ])
  )

  defcombinatorp(
    :arith_term,
    parsec(:arith_factor)
    |> repeat(
      ws
      |> concat(choice([string("*"), string("/")]) |> unwrap_and_tag(:op))
      |> concat(ws)
      |> concat(parsec(:arith_factor))
    )
    |> wrap()
    |> post_traverse({__MODULE__, :__fold_arith_wrapped__, []})
  )

  defcombinatorp(
    :arith_expr,
    parsec(:arith_term)
    |> repeat(
      ws
      |> concat(choice([string("+"), string("-")]) |> unwrap_and_tag(:op))
      |> concat(ws)
      |> concat(parsec(:arith_term))
    )
    |> wrap()
    |> post_traverse({__MODULE__, :__fold_arith_wrapped__, []})
  )

  # ---- list literal ------------------------------------------------------

  list_literal =
    ignore(string("["))
    |> concat(ws)
    |> optional(
      literal
      |> repeat(
        ws
        |> ignore(string(","))
        |> concat(ws)
        |> concat(literal)
      )
    )
    |> concat(ws)
    |> ignore(string("]"))
    |> wrap()
    |> post_traverse({__MODULE__, :__lit_list__, []})

  # ---- comparison --------------------------------------------------------

  comp_rhs =
    choice([
      list_literal,
      parsec(:arith_expr) |> post_traverse({__MODULE__, :__arith_to_lit__, []})
    ])

  comp_op =
    choice([
      string("not")
      |> ignore(whitespace)
      |> concat(string("in"))
      |> replace("not in"),
      string("=="),
      string("!="),
      string("<="),
      string(">="),
      string("<"),
      string(">"),
      string("in")
    ])
    |> unwrap_and_tag(:cmp_op)

  compare =
    comp_lhs
    |> concat(ws)
    |> concat(comp_op)
    |> concat(ws)
    |> concat(comp_rhs)
    |> post_traverse({__MODULE__, :__compare__, []})

  # ---- boolean composition ----------------------------------------------

  defcombinatorp(
    :atom_expr,
    choice([
      ignore(string("("))
      |> concat(ws)
      |> parsec(:expr)
      |> concat(ws)
      |> ignore(string(")")),
      compare
    ])
  )

  defcombinatorp(
    :not_expr,
    choice([
      ignore(string("not"))
      |> concat(whitespace)
      |> parsec(:not_expr)
      |> post_traverse({__MODULE__, :__not__, []}),
      parsec(:atom_expr)
    ])
  )

  defcombinatorp(
    :and_expr,
    parsec(:not_expr)
    |> repeat(
      whitespace
      |> ignore(string("and"))
      |> concat(whitespace)
      |> concat(parsec(:not_expr))
    )
    |> wrap()
    |> post_traverse({__MODULE__, :__group_and__, []})
  )

  defcombinatorp(
    :or_expr,
    parsec(:and_expr)
    |> repeat(
      whitespace
      |> ignore(string("or"))
      |> concat(whitespace)
      |> concat(parsec(:and_expr))
    )
    |> wrap()
    |> post_traverse({__MODULE__, :__group_or__, []})
  )

  defcombinatorp(:expr, parsec(:or_expr))

  defparsec(
    :predicate,
    ws |> parsec(:expr) |> concat(ws) |> eos()
  )

  # ---- post-traverse callbacks ------------------------------------------

  @doc false
  def __check_not_reserved__(rest, [name | tail], context, _line, _offset) do
    if name in @reserved do
      {:error, "reserved word: #{name}"}
    else
      {rest, [name | tail], context}
    end
  end

  @doc false
  def __to_atom_value__(rest, [name | tail], context, _line, _offset) do
    atom = String.to_existing_atom(name)
    {rest, [{:val, atom} | tail], context}
  rescue
    ArgumentError -> {:error, "unknown atom :#{name}"}
  end

  @doc false
  def __wrap_value__(rest, [v | tail], context, _line, _offset) do
    {rest, [{:val, v} | tail], context}
  end

  @doc false
  def __field__(rest, [field_name, ns_name | tail], context, _line, _offset) do
    with {:ok, ns_atom} <- to_existing(ns_name),
         {:ok, field_atom} <- to_existing(field_name) do
      node =
        case ns_atom do
          :input -> {:program_input, field_atom}
          ns -> {:field, ns, field_atom}
        end

      {rest, [node | tail], context}
    else
      {:error, name} -> {:error, "unknown atom: #{name}"}
    end
  end

  defp to_existing(name) do
    {:ok, String.to_existing_atom(name)}
  rescue
    ArgumentError -> {:error, name}
  end

  @doc false
  def __length__(rest, [field_node | tail], context, _line, _offset) do
    {rest, [{:length, field_node} | tail], context}
  end

  @doc false
  def __arith_non_literal__(_rest, _args, _context, _line, _offset) do
    {:error, "arithmetic must be literal-only"}
  end

  @doc false
  def __fold_arith_wrapped__(rest, [tokens | tail], context, _line, _offset) do
    case tokens do
      [single] ->
        {rest, [single | tail], context}

      _ ->
        case fold_left(tokens) do
          {:ok, value} -> {rest, [value | tail], context}
          {:error, msg} -> {:error, msg}
        end
    end
  end

  defp fold_left([first | rest]) do
    Enum.reduce_while(rest_pairs(rest), {:ok, first}, fn {op, next}, {:ok, acc} ->
      with {:ok, l} <- as_number(acc),
           {:ok, r} <- as_number(next) do
        {:cont, {:ok, {:val, apply_op(op, l, r)}}}
      else
        {:error, msg} -> {:halt, {:error, msg}}
      end
    end)
  end

  defp rest_pairs([]), do: []

  defp rest_pairs([{:op, op}, value | rest]) do
    [{op, value} | rest_pairs(rest)]
  end

  defp as_number({:val, v}) when is_integer(v) or is_float(v), do: {:ok, v}
  defp as_number(_), do: {:error, "arithmetic must be literal-only"}

  defp apply_op("+", l, r), do: l + r
  defp apply_op("-", l, r), do: l - r
  defp apply_op("*", l, r), do: l * r
  defp apply_op("/", l, r), do: l / r

  @doc false
  def __arith_to_lit__(rest, [{:val, v} | tail], context, _line, _offset) do
    {rest, [{:lit, v} | tail], context}
  end

  def __arith_to_lit__(_rest, _args, _context, _line, _offset) do
    {:error, "arithmetic must be literal-only"}
  end

  @doc false
  def __lit_list__(rest, [tokens | tail], context, _line, _offset) do
    values = Enum.map(tokens, fn {:val, v} -> v end)
    {rest, [{:lit_list, values} | tail], context}
  end

  @doc false
  def __compare__(rest, [rhs, {:cmp_op, op_str}, lhs | tail], context, _line, _offset) do
    {rest, [{op_atom(op_str), lhs, rhs} | tail], context}
  end

  defp op_atom("=="), do: :eq
  defp op_atom("!="), do: :neq
  defp op_atom("<"), do: :lt
  defp op_atom("<="), do: :lte
  defp op_atom(">"), do: :gt
  defp op_atom(">="), do: :gte
  defp op_atom("in"), do: :in
  defp op_atom("not in"), do: :not_in

  @doc false
  def __not__(rest, [inner | tail], context, _line, _offset) do
    {rest, [{:not, inner} | tail], context}
  end

  @doc false
  def __group_and__(rest, [exprs | tail], context, _line, _offset) do
    case exprs do
      [single] -> {rest, [single | tail], context}
      multi -> {rest, [{:and, multi} | tail], context}
    end
  end

  @doc false
  def __group_or__(rest, [exprs | tail], context, _line, _offset) do
    case exprs do
      [single] -> {rest, [single | tail], context}
      multi -> {rest, [{:or, multi} | tail], context}
    end
  end
end
