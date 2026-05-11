defmodule Dsxir.Signature.StringFormTest do
  use ExUnit.Case, async: true

  alias Dsxir.Module.Info, as: ModuleInfo
  alias Dsxir.Signature.Compiled
  alias Dsxir.Signature.Field
  alias Dsxir.Signature.Runtime

  defmodule ClassFormSig do
    @moduledoc false
    use Dsxir.Signature

    signature do
      input(:question, :string)
      output(:answer, :string)
    end
  end

  defmodule InlineStringProgram do
    @moduledoc false
    use Dsxir.Module

    predictor(:foo, Dsxir.Predictor.Predict, signature: "question -> answer")

    def forward(prog, %{question: q}) do
      call(prog, :foo, %{question: q})
    end
  end

  test "from_string/1 returns tagged Compiled struct with parsed fields" do
    assert {:ok,
            %Compiled{fields: fields, instruction: nil, source: {:string, "question -> answer"}}} =
             Dsxir.Signature.from_string("question -> answer")

    assert [
             %Field{name: :question, kind: :input},
             %Field{name: :answer, kind: :output}
           ] = fields
  end

  test "from_string/2 sets instruction when provided" do
    assert {:ok, %Compiled{instruction: "explain"}} =
             Dsxir.Signature.from_string("question -> answer", instruction: "explain")
  end

  test "from_string/1 returns {:error, _} on parse failure" do
    assert {:error, :missing_arrow} = Dsxir.Signature.from_string("question answer")
  end

  test "from_string! produces same field names and kinds as class form" do
    %Compiled{fields: string_fields} = Dsxir.Signature.from_string!("question -> answer")
    class_fields = Runtime.fields(ClassFormSig)

    assert Enum.map(string_fields, & &1.name) == Enum.map(class_fields, & &1.name)
    assert Enum.map(string_fields, & &1.kind) == Enum.map(class_fields, & &1.kind)
  end

  test "from_string! raises Invalid.Signature on parse failure" do
    assert_raise Dsxir.Errors.Invalid.Signature, fn ->
      Dsxir.Signature.from_string!("question answer")
    end
  end

  test "predictor declared with string signature compiles to Compiled struct at compile time" do
    assert [decl] = ModuleInfo.module(InlineStringProgram)
    assert %Compiled{} = decl.signature
    assert Enum.map(Runtime.fields(decl.signature), & &1.name) == [:question, :answer]
  end

  test "invalid type token raises Invalid.Signature at compile time" do
    code =
      quote do
        defmodule BadInline do
          use Dsxir.Module

          predictor(:foo, Dsxir.Predictor.Predict, signature: "x: blob -> y")

          def forward(prog, _), do: prog
        end
      end

    assert_raise Dsxir.Errors.Invalid.Signature, fn ->
      Code.eval_quoted(code)
    end
  end
end
