defmodule Dsxir.ArtifactLoadTest do
  use ExUnit.Case, async: true

  alias Dsxir.Artifact
  alias Dsxir.Errors.Invalid.SignatureMismatch
  alias Dsxir.Optimizer.LabeledFewShot
  alias Dsxir.Program

  defmodule SigA do
    use Dsxir.Signature

    signature do
      input(:q, :string)
      output(:a, :string)
    end
  end

  defmodule SigB do
    use Dsxir.Signature

    signature do
      input(:q, :string)
      output(:answer, :string)
    end
  end

  defmodule ProgA do
    use Dsxir.Module

    predictor(:answer, Dsxir.Predictor.Predict, signature: SigA)

    def forward(p, i), do: call(p, :answer, i)
  end

  defmodule ProgB do
    use Dsxir.Module

    predictor(:answer, Dsxir.Predictor.Predict, signature: SigB)

    def forward(p, i), do: call(p, :answer, i)
  end

  defmodule ProgWithExtra do
    use Dsxir.Module

    predictor(:answer, Dsxir.Predictor.Predict, signature: SigA)
    predictor(:rerank, Dsxir.Predictor.Predict, signature: SigA)

    def forward(p, i), do: call(p, :answer, i)
  end

  defp ex(q, a), do: Dsxir.Example.new(%{q: q, a: a}, input_keys: [:q])

  defp save_compiled(prog_module, tmp_dir) do
    trainset = Enum.map(1..3, &ex("q#{&1}", "a#{&1}"))

    {:ok, compiled, _} =
      LabeledFewShot.compile(Program.new(prog_module), trainset, fn _, _, _ -> 1.0 end, [])

    path = Path.join(tmp_dir, "dsxir-load-#{:erlang.unique_integer([:positive])}.json")
    {:ok, ^path} = Artifact.save(compiled, path)
    path
  end

  @tag :tmp_dir
  test "happy roundtrip into the same module", %{tmp_dir: tmp_dir} do
    path = save_compiled(ProgA, tmp_dir)
    {:ok, prog} = Artifact.load(ProgA, path)

    state = Program.get_state(prog, :answer)
    assert length(state.demos) == 3

    [demo | _] = state.demos
    assert %Dsxir.Demo{kind: :labeled, example: %Dsxir.Example{}} = demo
    assert demo.example.data[:q] in ["q1", "q2", "q3"]

    assert prog.metadata.compiled_with == LabeledFewShot
    assert is_binary(prog.metadata.trainset_hash)
  end

  @tag :tmp_dir
  test "demo without _kind field decodes as :labeled (backward compat)", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "dsxir-legacy-#{:erlang.unique_integer([:positive])}.json")

    legacy = %{
      "answer" => %{
        "instructions" => nil,
        "demos" => [%{"q" => "q1", "a" => "a1"}]
      },
      "_metadata" => %{
        "compiled_with" => nil,
        "score" => nil,
        "trainset_hash" => nil
      }
    }

    File.write!(path, Jason.encode!(legacy))

    {:ok, prog} = Artifact.load(ProgA, path)
    state = Program.get_state(prog, :answer)

    assert [%Dsxir.Demo{kind: :labeled, example: %Dsxir.Example{data: %{q: "q1", a: "a1"}}}] =
             state.demos
  end

  @tag :tmp_dir
  test "demo with _kind => bootstrapped decodes as :bootstrapped", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "dsxir-bootstrap-#{:erlang.unique_integer([:positive])}.json")

    payload = %{
      "answer" => %{
        "instructions" => nil,
        "demos" => [%{"q" => "q1", "a" => "a1", "_kind" => "bootstrapped"}]
      },
      "_metadata" => %{
        "compiled_with" => nil,
        "score" => nil,
        "trainset_hash" => nil
      }
    }

    File.write!(path, Jason.encode!(payload))

    {:ok, prog} = Artifact.load(ProgA, path)
    state = Program.get_state(prog, :answer)

    assert [%Dsxir.Demo{kind: :bootstrapped, example: %Dsxir.Example{data: %{q: "q1", a: "a1"}}}] =
             state.demos
  end

  @tag :tmp_dir
  test "_kind field never appears in field_diffs on same-module reload", %{tmp_dir: tmp_dir} do
    path = save_compiled(ProgA, tmp_dir)

    {:ok, prog} = Artifact.load(ProgA, path)

    state = Program.get_state(prog, :answer)
    assert Enum.all?(state.demos, &match?(%Dsxir.Demo{kind: :labeled}, &1))
  end

  @tag :tmp_dir
  test "load into module with missing predictor produces SignatureMismatch with :extra_predictors",
       %{tmp_dir: tmp_dir} do
    path = save_compiled(ProgWithExtra, tmp_dir)
    {:error, %SignatureMismatch{diff: diff}} = Artifact.load(ProgA, path)
    assert :rerank in diff.extra_predictors
  end

  @tag :tmp_dir
  test "load into module with extra predictor produces SignatureMismatch with :missing_predictors",
       %{tmp_dir: tmp_dir} do
    path = save_compiled(ProgA, tmp_dir)
    {:error, %SignatureMismatch{diff: diff}} = Artifact.load(ProgWithExtra, path)
    assert :rerank in diff.missing_predictors
  end

  @tag :tmp_dir
  test "load into module with mismatched field produces field_diffs entry", %{tmp_dir: tmp_dir} do
    path = save_compiled(ProgA, tmp_dir)
    {:error, %SignatureMismatch{diff: diff}} = Artifact.load(ProgB, path)
    assert %{answer: %{missing_fields: missing, extra_fields: extra}} = diff.field_diffs
    assert :answer in missing
    assert :a in extra
  end

  @tag :tmp_dir
  test "malformed JSON returns {:error, %Jason.DecodeError{}}", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "dsxir-bad-#{:erlang.unique_integer([:positive])}.json")
    File.write!(path, "{not json")
    assert {:error, %Jason.DecodeError{}} = Artifact.load(ProgA, path)
  end

  test "missing file returns {:error, %File.Error{reason: :enoent}}" do
    assert {:error, %File.Error{reason: :enoent}} =
             Artifact.load(ProgA, "/nonexistent/dsxir-load/path.json")
  end

  @tag :tmp_dir
  test "load!/3 raises on SignatureMismatch", %{tmp_dir: tmp_dir} do
    path = save_compiled(ProgA, tmp_dir)
    assert_raise SignatureMismatch, fn -> Artifact.load!(ProgB, path) end
  end

  @tag :tmp_dir
  test "custom metadata keys survive save/load roundtrip", %{tmp_dir: tmp_dir} do
    trainset = Enum.map(1..3, &ex("q#{&1}", "a#{&1}"))

    {:ok, compiled, _} =
      LabeledFewShot.compile(Program.new(ProgA), trainset, fn _, _, _ -> 1.0 end, [])

    enriched = %{compiled | metadata: Map.put(compiled.metadata, :custom_key, "value")}

    path = Path.join(tmp_dir, "dsxir-custom-meta-#{:erlang.unique_integer([:positive])}.json")
    {:ok, ^path} = Artifact.save(enriched, path)

    {:ok, loaded} = Artifact.load(ProgA, path)

    assert loaded.metadata[:custom_key] == "value"
    assert loaded.metadata.compiled_with == LabeledFewShot
  end
end
