defmodule Dsxir.ArtifactSaveTest do
  use ExUnit.Case, async: true

  alias Dsxir.Artifact
  alias Dsxir.Optimizer.LabeledFewShot
  alias Dsxir.Program

  defmodule Sig do
    @moduledoc "Answer the question."

    use Dsxir.Signature

    signature do
      input(:q, :string)
      output(:a, :string)
    end
  end

  defmodule Prog do
    use Dsxir.Module

    predictor(:answer, Dsxir.Predictor.Predict, signature: Sig)

    def forward(p, inputs), do: call(p, :answer, inputs)
  end

  defp ex(q, a), do: Dsxir.Example.new(%{q: q, a: a}, input_keys: [:q])

  test "encodes uncompiled program with empty demos and signature instructions" do
    encoded = Artifact.encode(Program.new(Prog))

    assert %{"answer" => %{"instructions" => instr, "demos" => []}} = encoded
    assert is_binary(instr) or is_nil(instr)

    assert encoded["_metadata"] == %{
             "compiled_with" => nil,
             "score" => nil,
             "trainset_hash" => nil
           }
  end

  test "encodes compiled program with demos and stamped metadata" do
    trainset = Enum.map(1..3, &ex("q#{&1}", "a#{&1}"))

    {:ok, compiled, _} =
      LabeledFewShot.compile(Program.new(Prog), trainset, fn _, _, _ -> 1.0 end, [])

    encoded = Artifact.encode(compiled)

    assert length(encoded["answer"]["demos"]) == 3

    Enum.each(encoded["answer"]["demos"], fn demo ->
      assert is_binary(demo["q"])
      assert is_binary(demo["a"])
      assert demo["_kind"] == "labeled"
    end)

    assert encoded["_metadata"]["compiled_with"] == "Elixir.Dsxir.Optimizer.LabeledFewShot"
    assert is_binary(encoded["_metadata"]["trainset_hash"])
  end

  test "encodes %Dsxir.Demo{kind: :bootstrapped} demos with _kind => bootstrapped" do
    demo = Dsxir.Demo.bootstrapped(ex("q1", "a1"), %{round: 1, example_index: 0})

    prog = %Program{
      module: Prog,
      predictors: %{answer: %Program.State{demos: [demo]}}
    }

    encoded = Artifact.encode(prog)
    assert [%{"q" => "q1", "a" => "a1", "_kind" => "bootstrapped"}] = encoded["answer"]["demos"]
  end

  test "encodes bare %Dsxir.Example{} demos with _kind => labeled" do
    prog = %Program{
      module: Prog,
      predictors: %{answer: %Program.State{demos: [ex("q1", "a1")]}}
    }

    encoded = Artifact.encode(prog)
    assert [%{"q" => "q1", "a" => "a1", "_kind" => "labeled"}] = encoded["answer"]["demos"]
  end

  @tag :tmp_dir
  test "save/2 writes pretty JSON to disk and creates parent dirs", %{tmp_dir: tmp_dir} do
    path = Path.join([tmp_dir, "nested", "a.json"])

    assert {:ok, ^path} = Artifact.save(Program.new(Prog), path)
    assert File.exists?(path)

    raw = File.read!(path)
    assert String.ends_with?(raw, "\n")
    assert String.contains?(raw, "\n  ")

    decoded = Jason.decode!(raw)
    assert Map.has_key?(decoded, "answer")
    assert Map.has_key?(decoded, "_metadata")
  end

  @tag :tmp_dir
  test "save!/2 raises on encode failure", %{tmp_dir: tmp_dir} do
    bad = %Program{
      module: Prog,
      predictors: %{answer: %Program.State{demos: [Dsxir.Example.new(%{q: self(), a: "x"})]}}
    }

    path = Path.join(tmp_dir, "bad.json")

    assert_raise Protocol.UndefinedError, fn -> Artifact.save!(bad, path) end
  end

  test "encode_demo accepts raw map demos without crashing" do
    prog = %Program{
      module: Prog,
      predictors: %{answer: %Program.State{demos: [%{q: "q1", a: "a1"}]}}
    }

    encoded = Artifact.encode(prog)

    assert [%{"q" => "q1", "a" => "a1"}] = encoded["answer"]["demos"]
  end
end
