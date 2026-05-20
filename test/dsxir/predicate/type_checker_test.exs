defmodule Dsxir.Predicate.TypeCheckerTest do
  use ExUnit.Case, async: true

  alias Dsxir.Predicate

  for atom <- [
        :user,
        :age,
        :country,
        :score,
        :status,
        :active,
        :pending,
        :tags,
        :text,
        :unknown_field,
        :a,
        :b,
        :br
      ] do
    _ = atom
  end

  defp parse!(src) do
    {:ok, ast} = Predicate.parse(src)
    ast
  end

  describe "root must be boolean" do
    test "accepts a comparison" do
      env = %{user: %{age: :integer}}
      assert :ok = Predicate.type_check(parse!("user.age > 0"), env)
    end

    test "accepts and/or/not composition" do
      env = %{user: %{age: :integer, country: :atom}}

      assert :ok =
               Predicate.type_check(
                 parse!("user.age > 0 and user.country == :br"),
                 env
               )

      assert :ok = Predicate.type_check(parse!("not user.age == 0"), env)
    end

    test "rejects a comparison with mismatched lhs/rhs types" do
      assert {:error, %{code: :predicate_type_error}} =
               Predicate.type_check(parse!("user.age == 1"), %{user: %{age: :string}})
    end
  end

  describe "length/1" do
    test "accepts string field, returns integer" do
      env = %{program_input: %{text: :string}}
      assert :ok = Predicate.type_check(parse!("length(input.text) > 10"), env)
    end

    test "accepts list field" do
      env = %{user: %{tags: {:list, :atom}}}
      assert :ok = Predicate.type_check(parse!("length(user.tags) > 0"), env)
    end

    test "rejects non-string/non-list field" do
      env = %{user: %{age: :integer}}

      assert {:error, %{code: :predicate_type_error}} =
               Predicate.type_check(parse!("length(user.age) > 0"), env)
    end

    test "integer-returning length compares against a float literal" do
      env = %{program_input: %{q: :string}}
      assert :ok = Predicate.type_check(parse!("length(input.q) > 1.5"), env)
    end
  end

  describe "numeric compatibility" do
    test "integer field compared to float literal type-checks" do
      env = %{user: %{age: :integer}}
      assert :ok = Predicate.type_check(parse!("user.age > 0.5"), env)
    end

    test "float field compared to integer literal type-checks" do
      env = %{user: %{score: :float}}
      assert :ok = Predicate.type_check(parse!("user.score > 1"), env)
    end
  end

  describe "comparison" do
    test "rejects type mismatch between lhs and rhs" do
      env = %{user: %{age: :integer}}

      assert {:error, %{code: :predicate_type_error}} =
               Predicate.type_check(parse!(~s(user.age == "hello")), env)
    end

    test "in: list element type must match value type" do
      env = %{user: %{status: :atom}}
      assert :ok = Predicate.type_check(parse!("user.status in [:a, :b]"), env)

      assert {:error, %{code: :predicate_type_error}} =
               Predicate.type_check(parse!("user.status in [1, 2]"), env)
    end
  end

  describe "unknown field" do
    test "unknown namespace" do
      assert {:error, %{code: :predicate_type_error}} =
               Predicate.type_check(parse!("user.age > 0"), %{})
    end

    test "unknown field within known namespace" do
      assert {:error, %{code: :predicate_type_error}} =
               Predicate.type_check(parse!("user.unknown_field > 0"), %{user: %{age: :integer}})
    end
  end
end
