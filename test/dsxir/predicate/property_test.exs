defmodule Dsxir.Predicate.PropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Dsxir.Predicate

  # Pre-declare every atom these properties may emit.
  for atom <- [:obj, :a, :b, :x, :y, :z, :status, :one, :two, :three, :input, :q] do
    _ = atom
  end

  @field_names [:a, :b, :x, :y, :z, :status, :q]

  defp generator_field do
    StreamData.one_of([
      gen all(ns <- StreamData.member_of([:obj]), f <- StreamData.member_of(@field_names)) do
        {ns, Atom.to_string(f), {:field, ns, f}, :integer}
      end,
      gen all(f <- StreamData.member_of(@field_names)) do
        {:program_input, Atom.to_string(f), {:program_input, f}, :integer}
      end
    ])
  end

  defp generator_int_lit, do: StreamData.integer(-1000..1000)

  defp generator_comparison do
    gen all(
          {ns, fname, ast_field, _type} <- generator_field(),
          op_src <- StreamData.member_of(["==", "!=", "<", "<=", ">", ">="]),
          rhs <- generator_int_lit()
        ) do
      lhs_src =
        case ns do
          :program_input -> "input.#{fname}"
          _ -> "#{ns}.#{fname}"
        end

      src = "#{lhs_src} #{op_src} #{rhs}"

      env_namespace =
        case ns do
          :program_input -> :program_input
          other -> other
        end

      env_value = %{env_namespace => %{(ast_field |> elem_field()) => rhs}}
      env_schema = %{env_namespace => %{(ast_field |> elem_field()) => :integer}}
      {src, env_value, env_schema}
    end
  end

  defp elem_field({:field, _ns, f}), do: f
  defp elem_field({:program_input, f}), do: f

  defp generator_bool_expr do
    gen all(
          comps <- StreamData.list_of(generator_comparison(), min_length: 1, max_length: 4),
          combinator <- StreamData.member_of(["and", "or"])
        ) do
      sources = Enum.map(comps, fn {s, _v, _s2} -> s end)
      src = Enum.join(sources, " #{combinator} ")

      merged_value =
        comps
        |> Enum.map(fn {_, v, _} -> v end)
        |> Enum.reduce(%{}, fn m, acc -> deep_merge(acc, m) end)

      merged_schema =
        comps
        |> Enum.map(fn {_, _, s} -> s end)
        |> Enum.reduce(%{}, fn m, acc -> deep_merge(acc, m) end)

      {src, merged_value, merged_schema}
    end
  end

  defp deep_merge(a, b) do
    Map.merge(a, b, fn _k, va, vb when is_map(va) and is_map(vb) ->
      Map.merge(va, vb)
    end)
  end

  property "format/1 . parse/1 round-trips (modulo constant folding)" do
    check all({src, _v, _s} <- generator_bool_expr()) do
      assert {:ok, ast} = Predicate.parse(src)
      formatted = Predicate.format(ast)
      assert {:ok, ast2} = Predicate.parse(formatted)
      assert ast.expr == ast2.expr
    end
  end

  property "evaluator is total on well-typed env" do
    check all({src, env_value, env_schema} <- generator_bool_expr()) do
      assert {:ok, ast} = Predicate.parse(src)
      assert :ok = Predicate.type_check(ast, env_schema)
      assert {:ok, b} = Predicate.eval(ast, env_value)
      assert is_boolean(b)
    end
  end

  property "malformed input returns a structured error with line/col" do
    malformed =
      StreamData.member_of([
        "",
        "(",
        ")",
        "a.x >",
        "a.x ==",
        "and",
        "a.x && 1",
        "a.x > * 3",
        "[a.x, 1]",
        "length(",
        "a.x.y == 1"
      ])

    check all(src <- malformed) do
      assert {:error, %{code: :predicate_parse_error, line: l, col: c}} =
               Predicate.parse(src)

      assert is_integer(l) and is_integer(c)
    end
  end
end
