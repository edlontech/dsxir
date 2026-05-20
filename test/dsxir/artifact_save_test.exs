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

    assert %{"format_version" => "2", "source_kind" => "module"} = encoded
    assert %{"predictors" => %{"answer" => %{"instructions" => instr, "demos" => []}}} = encoded
    assert is_binary(instr) or is_nil(instr)

    assert encoded["metadata"] == %{
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
    answer_block = encoded["predictors"]["answer"]

    assert length(answer_block["demos"]) == 3

    Enum.each(answer_block["demos"], fn demo ->
      assert is_binary(demo["q"])
      assert is_binary(demo["a"])
      assert demo["_kind"] == "labeled"
    end)

    assert encoded["metadata"]["compiled_with"] == "Elixir.Dsxir.Optimizer.LabeledFewShot"
    assert is_binary(encoded["metadata"]["trainset_hash"])
  end

  test "encodes %Dsxir.Demo{kind: :bootstrapped} demos with _kind => bootstrapped" do
    demo = Dsxir.Demo.bootstrapped(ex("q1", "a1"), %{round: 1, example_index: 0})

    prog = %Program{
      source: Dsxir.Program.Source.Module.new!(Prog),
      predictors: %{answer: %Program.State{demos: [demo]}}
    }

    encoded = Artifact.encode(prog)

    assert [%{"q" => "q1", "a" => "a1", "_kind" => "bootstrapped"}] =
             encoded["predictors"]["answer"]["demos"]
  end

  test "encodes bare %Dsxir.Example{} demos with _kind => labeled" do
    prog = %Program{
      source: Dsxir.Program.Source.Module.new!(Prog),
      predictors: %{answer: %Program.State{demos: [ex("q1", "a1")]}}
    }

    encoded = Artifact.encode(prog)

    assert [%{"q" => "q1", "a" => "a1", "_kind" => "labeled"}] =
             encoded["predictors"]["answer"]["demos"]
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
    assert decoded["format_version"] == "2"
    assert decoded["source_kind"] == "module"
    assert Map.has_key?(decoded["predictors"], "answer")
    assert Map.has_key?(decoded, "metadata")
  end

  @tag :tmp_dir
  test "save!/2 raises on encode failure", %{tmp_dir: tmp_dir} do
    bad = %Program{
      source: Dsxir.Program.Source.Module.new!(Prog),
      predictors: %{answer: %Program.State{demos: [Dsxir.Example.new(%{q: self(), a: "x"})]}}
    }

    path = Path.join(tmp_dir, "bad.json")

    assert_raise Protocol.UndefinedError, fn -> Artifact.save!(bad, path) end
  end

  test "encodes _miprov2_stats additively under _metadata" do
    stats = %Dsxir.Optimizer.MIPROv2.Stats{
      best_score: 0.75,
      best_config: %{{:answer, :instruction} => 1},
      proposer_calls: 2,
      total_task_lm_calls: 10,
      total_cached_calls: 3,
      degraded: false
    }

    prog = %Program{
      source: Dsxir.Program.Source.Module.new!(Prog),
      metadata: %{
        compiled_with: Dsxir.Optimizer.MIPROv2,
        score: 0.75,
        trainset_hash: "deadbeef",
        _miprov2_stats: stats
      }
    }

    encoded = Artifact.encode(prog)
    md = encoded["metadata"]

    assert md["compiled_with"] == "Elixir.Dsxir.Optimizer.MIPROv2"
    assert md["score"] == 0.75
    assert md["trainset_hash"] == "deadbeef"
    assert is_map(md["_miprov2_stats"])
    assert md["_miprov2_stats"]["best_score"] == 0.75
    assert md["_miprov2_stats"]["proposer_calls"] == 2

    json = Jason.encode!(encoded)
    decoded = Jason.decode!(json)
    {:ok, hydrated} = Artifact.decode(Prog, decoded)
    assert hydrated.metadata[:_miprov2_stats]["best_score"] == 0.75
  end

  test "encode_demo accepts raw map demos without crashing" do
    prog = %Program{
      source: Dsxir.Program.Source.Module.new!(Prog),
      predictors: %{answer: %Program.State{demos: [%{q: "q1", a: "a1"}]}}
    }

    encoded = Artifact.encode(prog)

    assert [%{"q" => "q1", "a" => "a1"}] = encoded["predictors"]["answer"]["demos"]
  end
end
