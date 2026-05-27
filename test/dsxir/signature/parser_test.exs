defmodule Dsxir.Signature.ParserTest do
  use ExUnit.Case, async: true

  alias Dsxir.Signature.Compiled
  alias Dsxir.Signature.Field
  alias Dsxir.Signature.Parser

  test "parses single-input single-output with implicit string type" do
    assert {:ok, %Compiled{fields: fields, instruction: nil, source: {:string, source}}} =
             Parser.parse("question -> answer")

    assert source == "question -> answer"

    assert [
             %Field{name: :question, type: "str", kind: :input, desc: nil},
             %Field{name: :answer, type: "str", kind: :output, desc: nil}
           ] = fields

    [%Field{zoi: in_zoi}, %Field{zoi: out_zoi}] = fields
    assert {:ok, "hi"} = Zoi.parse(in_zoi, "hi")
    assert {:ok, "ok"} = Zoi.parse(out_zoi, "ok")
  end

  test "parses explicit types and list[str]" do
    assert {:ok, %Compiled{fields: fields}} =
             Parser.parse("transcript: str -> summary: str, action_items: list[str]")

    assert [
             %Field{name: :transcript, type: "str", kind: :input},
             %Field{name: :summary, type: "str", kind: :output},
             %Field{name: :action_items, type: "list[str]", kind: :output, zoi: list_zoi}
           ] = fields

    assert {:ok, ["a", "b"]} = Zoi.parse(list_zoi, ["a", "b"])
  end

  test "returns error for unknown type tokens" do
    assert {:error, {:unknown_type, "blob"}} = Parser.parse("x: blob -> y")
  end

  test "returns error when arrow is missing" do
    assert {:error, :missing_arrow} = Parser.parse("question answer")
  end

  test "parses nested list[list[int]] correctly" do
    assert {:ok, %Compiled{fields: fields}} = Parser.parse("xs: list[list[int]] -> y: int")

    assert [
             %Field{name: :xs, type: "list[list[int]]", kind: :input, zoi: outer_zoi},
             %Field{name: :y, type: "int", kind: :output}
           ] = fields

    assert {:ok, [[1, 2], [3]]} = Zoi.parse(outer_zoi, [[1, 2], [3]])
  end

  test "parses all scalar types" do
    assert {:ok, %Compiled{fields: fields}} =
             Parser.parse("a: str, b: int, c: float, d: bool, e: dict -> ok: bool")

    assert Enum.map(fields, & &1.type) == ["str", "int", "float", "bool", "dict", "bool"]
    assert Enum.map(fields, & &1.kind) == [:input, :input, :input, :input, :input, :output]
  end

  test "rejects empty inputs side" do
    assert {:error, :empty_inputs} = Parser.parse(" -> answer")
  end

  test "rejects empty outputs side" do
    assert {:error, :empty_outputs} = Parser.parse("q -> ")
  end

  test "rejects empty inter-comma slot" do
    assert {:error, :empty_field} = Parser.parse("a, , b -> y")
  end

  test "rejects trailing empty slot" do
    assert {:error, :empty_field} = Parser.parse("a, -> y")
  end

  test "default mode mints new atoms for unseen field names" do
    name = "fresh_create_#{System.unique_integer([:positive])}"

    assert {:ok, %Compiled{fields: [%Field{name: created} | _]}} =
             Parser.parse("#{name} -> answer")

    assert Atom.to_string(created) == name
  end

  test "atoms: :existing resolves names already interned" do
    _ = [:existing_in_x, :existing_out_y]

    assert {:ok, %Compiled{fields: [%Field{name: :existing_in_x}, %Field{name: :existing_out_y}]}} =
             Parser.parse("existing_in_x -> existing_out_y", atoms: :existing)
  end

  test "atoms: :existing rejects unknown field names instead of minting atoms" do
    name = "never_interned_#{System.unique_integer([:positive])}"

    assert {:error, {:unknown_field, ^name}} =
             Parser.parse("#{name} -> answer", atoms: :existing)
  end
end
