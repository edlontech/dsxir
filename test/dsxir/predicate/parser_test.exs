defmodule Dsxir.Predicate.ParserTest do
  use ExUnit.Case, async: true

  alias Dsxir.Predicate
  alias Dsxir.Predicate.AST

  # Pre-declare every atom this module's tests pass to `String.to_existing_atom`
  # so the parser can resolve them. `Module.put_attribute/3` keeps the list
  # alive without producing an "unused attribute" warning.
  for atom <- [
        :user,
        :age,
        :score,
        :name,
        :status,
        :status_active,
        :active,
        :avatar,
        :foo,
        :answer,
        :text,
        :q,
        :pending,
        :banned,
        :red,
        :blue,
        :green,
        :a,
        :x,
        :y,
        :z,
        :br,
        :country
      ] do
    _ = atom
  end

  describe "literals" do
    test "parses an integer literal compared against a field" do
      assert {:ok, %AST{expr: {:eq, {:field, :user, :age}, {:lit, 42}}}} =
               Predicate.parse("user.age == 42")
    end

    test "parses a negative integer literal" do
      assert {:ok, %AST{expr: {:eq, {:field, :user, :age}, {:lit, -7}}}} =
               Predicate.parse("user.age == -7")
    end

    test "parses a float literal" do
      assert {:ok, %AST{expr: {:lt, {:field, :user, :score}, {:lit, 1.5}}}} =
               Predicate.parse("user.score < 1.5")
    end

    test "parses a string literal with escaped quote" do
      assert {:ok, %AST{expr: {:eq, {:field, :user, :name}, {:lit, ~s(a"b)}}}} =
               Predicate.parse(~s(user.name == "a\\"b"))
    end

    test "parses an atom literal" do
      :status_active
      :red

      assert {:ok, %AST{expr: {:eq, {:field, :user, :status}, {:lit, :status_active}}}} =
               Predicate.parse("user.status == :status_active")
    end

    test "parses booleans and nil" do
      assert {:ok, %AST{expr: {:eq, {:field, :user, :active}, {:lit, true}}}} =
               Predicate.parse("user.active == true")

      assert {:ok, %AST{expr: {:eq, {:field, :user, :active}, {:lit, false}}}} =
               Predicate.parse("user.active == false")

      assert {:ok, %AST{expr: {:eq, {:field, :user, :avatar}, {:lit, nil}}}} =
               Predicate.parse("user.avatar == nil")
    end
  end

  describe "fields" do
    test "parses a field reference" do
      assert {:ok, %AST{expr: {:eq, {:field, :user, :age}, {:lit, 1}}}} =
               Predicate.parse("user.age == 1")
    end

    test "special-cases input.* to {:program_input, _}" do
      assert {:ok, %AST{expr: {:eq, {:program_input, :foo}, {:lit, 1}}}} =
               Predicate.parse("input.foo == 1")
    end

    test "rejects unknown atom for a field namespace" do
      assert {:error, %{code: :predicate_parse_error}} =
               Predicate.parse("zzz_definitely_not_an_atom_xyz.bar == 1")
    end
  end

  describe "length/1" do
    test "wraps a field reference in a :length node" do
      assert {:ok, %AST{expr: {:gt, {:length, {:field, :answer, :text}}, {:lit, 0}}}} =
               Predicate.parse("length(answer.text) > 0")
    end

    test "wraps a program_input field" do
      assert {:ok, %AST{expr: {:gt, {:length, {:program_input, :q}}, {:lit, 10}}}} =
               Predicate.parse("length(input.q) > 10")
    end
  end

  describe "comparison operators" do
    for {src, op} <- [
          {"==", :eq},
          {"!=", :neq},
          {"<", :lt},
          {"<=", :lte},
          {">", :gt},
          {">=", :gte}
        ] do
      test "parses #{src} as #{op}" do
        src = unquote(src)
        op = unquote(op)

        assert {:ok, %AST{expr: {^op, {:field, :user, :age}, {:lit, 1}}}} =
                 Predicate.parse("user.age #{src} 1")
      end
    end

    test "parses in with a list literal" do
      assert {:ok,
              %AST{
                expr: {:in, {:field, :user, :status}, {:lit_list, [:active, :pending]}}
              }} = Predicate.parse("user.status in [:active, :pending]")
    end

    test "parses not in with a list literal" do
      assert {:ok,
              %AST{
                expr: {:not_in, {:field, :user, :status}, {:lit_list, [:banned]}}
              }} = Predicate.parse("user.status not in [:banned]")
    end
  end

  describe "arithmetic folding on RHS" do
    test "folds addition" do
      assert {:ok, %AST{expr: {:gt, {:length, {:program_input, :q}}, {:lit, 8}}}} =
               Predicate.parse("length(input.q) > 5 + 3")
    end

    test "folds multiplication and respects precedence" do
      assert {:ok, %AST{expr: {:gt, {:length, {:program_input, :q}}, {:lit, 11}}}} =
               Predicate.parse("length(input.q) > 5 + 3 * 2")
    end

    test "folds parenthesised arithmetic" do
      assert {:ok, %AST{expr: {:gt, {:length, {:program_input, :q}}, {:lit, 16}}}} =
               Predicate.parse("length(input.q) > (5 + 3) * 2")
    end

    test "folds float division" do
      assert {:ok, %AST{expr: {:lt, {:field, :user, :score}, {:lit, 2.5}}}} =
               Predicate.parse("user.score < 5 / 2")
    end

    test "rejects non-literal arithmetic" do
      assert {:error, %{code: :predicate_parse_error, message: msg}} =
               Predicate.parse("length(input.q) > x.y + 1")

      assert msg =~ "arithmetic must be literal-only"
    end
  end

  describe "boolean composition" do
    test "parses and" do
      assert {:ok,
              %AST{
                expr:
                  {:and,
                   [
                     {:gt, {:field, :a, :x}, {:lit, 0}},
                     {:lt, {:field, :a, :y}, {:lit, 10}}
                   ]}
              }} = Predicate.parse("a.x > 0 and a.y < 10")
    end

    test "parses or" do
      assert {:ok,
              %AST{
                expr:
                  {:or,
                   [
                     {:eq, {:field, :a, :x}, {:lit, 1}},
                     {:eq, {:field, :a, :x}, {:lit, 2}}
                   ]}
              }} = Predicate.parse("a.x == 1 or a.x == 2")
    end

    test "parses not as prefix" do
      assert {:ok, %AST{expr: {:not, {:eq, {:field, :a, :x}, {:lit, nil}}}}} =
               Predicate.parse("not a.x == nil")
    end

    test "and binds tighter than or" do
      assert {:ok,
              %AST{
                expr:
                  {:or,
                   [
                     {:and,
                      [
                        {:gt, {:field, :a, :x}, {:lit, 0}},
                        {:lt, {:field, :a, :y}, {:lit, 10}}
                      ]},
                     {:eq, {:field, :a, :z}, {:lit, 1}}
                   ]}
              }} =
               Predicate.parse("a.x > 0 and a.y < 10 or a.z == 1")
    end

    test "parentheses override precedence" do
      assert {:ok,
              %AST{
                expr:
                  {:and,
                   [
                     {:gt, {:field, :a, :x}, {:lit, 0}},
                     {:or,
                      [
                        {:lt, {:field, :a, :y}, {:lit, 10}},
                        {:eq, {:field, :a, :z}, {:lit, 1}}
                      ]}
                   ]}
              }} =
               Predicate.parse("a.x > 0 and (a.y < 10 or a.z == 1)")
    end
  end

  describe "errors" do
    test "missing operand" do
      assert {:error, %{code: :predicate_parse_error, line: l, col: c}} =
               Predicate.parse("a.x >")

      assert is_integer(l) and is_integer(c)
    end

    test "unmatched paren" do
      assert {:error, %{code: :predicate_parse_error}} =
               Predicate.parse("(a.x > 0")
    end

    test "reserved word as identifier" do
      assert {:error, %{code: :predicate_parse_error}} =
               Predicate.parse("and.x == 1")
    end

    test "empty input" do
      assert {:error, %{code: :predicate_parse_error}} = Predicate.parse("")
    end
  end

  describe "format/1" do
    test "returns the original source string" do
      # Ensure atoms exist (String.to_existing_atom safety).
      _ = [:user, :age, :country, :br]
      src = "user.age > 18 and user.country == :br"
      assert {:ok, ast} = Predicate.parse(src)
      assert Predicate.format(ast) == src
    end
  end
end
