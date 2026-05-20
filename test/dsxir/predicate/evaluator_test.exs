defmodule Dsxir.Predicate.EvaluatorTest do
  use ExUnit.Case, async: true

  alias Dsxir.Predicate

  for atom <- [
        :user,
        :age,
        :status,
        :active,
        :pending,
        :banned,
        :tags,
        :text,
        :missing,
        :a,
        :b,
        :c,
        :x,
        :y
      ] do
    _ = atom
  end

  defp parse!(src) do
    {:ok, ast} = Predicate.parse(src)
    ast
  end

  describe "comparison operators" do
    test "==" do
      assert {:ok, true} = Predicate.eval(parse!("user.age == 18"), %{user: %{age: 18}})
      assert {:ok, false} = Predicate.eval(parse!("user.age == 18"), %{user: %{age: 19}})
    end

    test "!=" do
      assert {:ok, true} = Predicate.eval(parse!("user.age != 18"), %{user: %{age: 19}})
      assert {:ok, false} = Predicate.eval(parse!("user.age != 18"), %{user: %{age: 18}})
    end

    test "<, <=, >, >=" do
      env = %{user: %{age: 18}}
      assert {:ok, true} = Predicate.eval(parse!("user.age < 19"), env)
      assert {:ok, false} = Predicate.eval(parse!("user.age < 18"), env)
      assert {:ok, true} = Predicate.eval(parse!("user.age <= 18"), env)
      assert {:ok, true} = Predicate.eval(parse!("user.age > 17"), env)
      assert {:ok, true} = Predicate.eval(parse!("user.age >= 18"), env)
    end

    test "in and not in" do
      env = %{user: %{status: :active}}
      assert {:ok, true} = Predicate.eval(parse!("user.status in [:active, :pending]"), env)
      assert {:ok, false} = Predicate.eval(parse!("user.status in [:banned]"), env)
      assert {:ok, true} = Predicate.eval(parse!("user.status not in [:banned]"), env)
    end
  end

  describe "length/1" do
    test "computes string length" do
      env = %{program_input: %{text: "hello"}}
      assert {:ok, true} = Predicate.eval(parse!("length(input.text) == 5"), env)
    end

    test "computes list length" do
      env = %{user: %{tags: [:a, :b, :c]}}
      assert {:ok, true} = Predicate.eval(parse!("length(user.tags) == 3"), env)
    end
  end

  describe "boolean composition" do
    test "and is true only when both branches true" do
      env = %{a: %{x: 5, y: 5}}
      assert {:ok, true} = Predicate.eval(parse!("a.x > 0 and a.y < 10"), env)
      assert {:ok, false} = Predicate.eval(parse!("a.x > 10 and a.y < 10"), env)
    end

    test "or is true when either branch true" do
      env = %{a: %{x: 5}}
      assert {:ok, true} = Predicate.eval(parse!("a.x == 5 or a.x == 6"), env)
      assert {:ok, false} = Predicate.eval(parse!("a.x == 7 or a.x == 6"), env)
    end

    test "not flips" do
      env = %{a: %{x: 5}}
      assert {:ok, false} = Predicate.eval(parse!("not a.x == 5"), env)
      assert {:ok, true} = Predicate.eval(parse!("not a.x == 6"), env)
    end

    test "and short-circuits: rhs not evaluated when lhs false" do
      env = %{a: %{x: 0}}
      assert {:ok, false} = Predicate.eval(parse!("a.x > 0 and a.missing == 1"), env)
    end

    test "or short-circuits: rhs not evaluated when lhs true" do
      env = %{a: %{x: 1}}
      assert {:ok, true} = Predicate.eval(parse!("a.x == 1 or a.missing == 1"), env)
    end
  end

  describe "runtime type mismatch" do
    test "comparing integer to string returns :type_mismatch" do
      env = %{user: %{age: "not a number"}}

      assert {:error, %{code: :type_mismatch}} =
               Predicate.eval(parse!("user.age > 0"), env)
    end

    test "length on non-string/list returns :type_mismatch" do
      env = %{user: %{age: 42}}

      assert {:error, %{code: :type_mismatch}} =
               Predicate.eval(parse!("length(user.age) > 0"), env)
    end
  end
end
