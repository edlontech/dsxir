defmodule Dsxir.Artifact.V2RoundTripTest do
  use ExUnit.Case, async: true

  alias Dsxir.Artifact
  alias Dsxir.Errors.Invalid
  alias Dsxir.Program
  alias Dsxir.Test.Fixtures.RuntimePrograms

  defmodule Sig do
    @moduledoc false
    use Dsxir.Signature

    signature do
      input(:q, :string)
      output(:a, :string)
    end
  end

  defmodule Prog do
    @moduledoc false
    use Dsxir.Module

    predictor(:answer, Dsxir.Predictor.Predict, signature: Sig)

    def forward(p, inputs), do: call(p, :answer, inputs)
  end

  defmodule WrongProg do
    @moduledoc false
    use Dsxir.Module

    predictor(:answer, Dsxir.Predictor.Predict, signature: Sig)

    def forward(p, inputs), do: call(p, :answer, inputs)
  end

  defp ex(q, a), do: Dsxir.Example.new(%{q: q, a: a}, input_keys: [:q])

  test "%Program{} with Source.Module round-trips through v2 encode/decode" do
    prog = %Program{
      source: Dsxir.Program.Source.Module.new!(Prog),
      predictors: %{
        answer: %Program.State{
          demos: [
            %Dsxir.Demo{example: ex("q1", "a1"), kind: :labeled},
            %Dsxir.Demo{example: ex("q2", "a2"), kind: :bootstrapped}
          ],
          instructions_override: "override"
        }
      },
      metadata: %{compiled_with: nil, score: 0.9, trainset_hash: "hash"}
    }

    json = prog |> Artifact.encode() |> Jason.encode!()
    loaded = Artifact.decode_and_hydrate(json)

    assert loaded.source.__struct__ == prog.source.__struct__
    assert loaded.source.module == Prog
    state = Program.get_state(loaded, :answer)
    assert length(state.demos) == 2
    assert state.instructions_override == "override"
    assert loaded.metadata.score == 0.9
    assert loaded.metadata.trainset_hash == "hash"
  end

  test "%Program{} with Source.RuntimeProgram round-trips through v2 encode/decode" do
    rp = RuntimePrograms.linear_chain()
    prog = Program.from_runtime(rp)

    json = prog |> Artifact.encode() |> Jason.encode!()
    loaded = Artifact.decode_and_hydrate(json)

    assert %Dsxir.Program.Source.RuntimeProgram{runtime_program: loaded_rp} = loaded.source
    assert loaded_rp.id == rp.id
    assert loaded_rp.version == rp.version
    assert length(loaded_rp.nodes) == length(rp.nodes)
    assert length(loaded_rp.edges) == length(rp.edges)
  end

  test "encoded map always has format_version 2 (save-as-v1 unsupported)" do
    prog = Program.new(Prog)
    assert %{"format_version" => "2"} = Artifact.encode(prog)

    rp = RuntimePrograms.linear_chain()
    runtime_prog = Program.from_runtime(rp)
    assert %{"format_version" => "2"} = Artifact.encode(runtime_prog)
  end

  test "encoded runtime program carries source_kind: runtime" do
    rp = RuntimePrograms.linear_chain()
    prog = Program.from_runtime(rp)
    encoded = Artifact.encode(prog)
    assert encoded["source_kind"] == "runtime"
    assert is_map(encoded["source"])
    assert encoded["source"]["id"] == rp.id
  end

  test "encoded module program carries source_kind: module" do
    prog = Program.new(Prog)
    encoded = Artifact.encode(prog)
    assert encoded["source_kind"] == "module"
    assert encoded["source"] == Atom.to_string(Prog)
  end

  test "guard sources persist as strings, never as parsed ASTs" do
    rp = RuntimePrograms.linear_chain()

    {:ok, ast} = Dsxir.Predicate.parse("length(step1.answer) > 0")

    guarded_nodes =
      List.update_at(rp.nodes, 1, fn n ->
        %{n | guard: %Dsxir.Predicate.Source{source: ast.source, ast: ast}}
      end)

    rp = %{rp | nodes: guarded_nodes}
    rp = %{rp | version: Dsxir.RuntimeProgram.version!(rp)}
    prog = Program.from_runtime(rp)

    encoded = Artifact.encode(prog)
    [_first, second] = encoded["source"]["nodes"]
    assert second["guard_source"] == "length(step1.answer) > 0"
    refute Map.has_key?(second, "guard_ast")
  end

  test "tampered guard_source on load triggers re-validation failure" do
    rp = RuntimePrograms.linear_chain()
    prog = Program.from_runtime(rp)

    encoded = Artifact.encode(prog)

    tampered =
      put_in(encoded, ["source", "nodes", Access.at(0), "guard_source"], ")))) bad syntax")

    json = Jason.encode!(tampered)

    assert_raise Invalid.RuntimeProgram, fn ->
      Artifact.decode_and_hydrate(json)
    end
  end

  test "tampered metadata with original version hex triggers :version_mismatch on load" do
    rp =
      RuntimePrograms.linear_chain()
      |> Map.put(:metadata, %{"description" => "v1"})

    rp = %{rp | version: Dsxir.RuntimeProgram.version!(rp)}
    prog = Program.from_runtime(rp)

    encoded = Artifact.encode(prog)

    tampered_source = Map.put(encoded["source"], "metadata", %{"note" => "altered"})
    tampered = Map.put(encoded, "source", tampered_source)

    json = Jason.encode!(tampered)

    err =
      try do
        Artifact.decode_and_hydrate(json)
        flunk("expected Invalid.RuntimeProgram with :version_mismatch")
      rescue
        e in Invalid.RuntimeProgram -> e
      end

    assert Enum.any?(err.errors, fn entry ->
             entry.code == :version_mismatch and entry.path == [:version]
           end),
           "expected a :version_mismatch entry at [:version]; got #{inspect(err.errors)}"
  end

  test "loaded runtime program carries fresh guard ASTs attached by validator" do
    rp = RuntimePrograms.linear_chain()

    guarded_nodes =
      List.update_at(rp.nodes, 1, fn n ->
        %{n | guard: %Dsxir.Predicate.Source{source: "length(step1.answer) > 0"}}
      end)

    rp = %{rp | nodes: guarded_nodes}
    rp = %{rp | version: Dsxir.RuntimeProgram.version!(rp)}
    prog = Program.from_runtime(rp)

    json = prog |> Artifact.encode() |> Jason.encode!()
    loaded = Artifact.decode_and_hydrate(json)

    [_first, second] = loaded.source.runtime_program.nodes
    assert %Dsxir.Predicate.Source{source: src, ast: %Dsxir.Predicate.AST{}} = second.guard
    assert src == "length(step1.answer) > 0"
  end

  test "predictor demos round-trip through runtime program v2" do
    rp = RuntimePrograms.linear_chain()
    prog = Program.from_runtime(rp)

    seeded = %{
      prog
      | predictors:
          Map.put(prog.predictors, :step1, %Program.State{
            demos: [%Dsxir.Demo{example: ex("hello", "world"), kind: :bootstrapped}]
          })
    }

    json = seeded |> Artifact.encode() |> Jason.encode!()
    loaded = Artifact.decode_and_hydrate(json)

    state = Program.get_state(loaded, :step1)
    assert [%Dsxir.Demo{kind: :bootstrapped}] = state.demos
  end

  test "decode/2 rejects v2 module artifact loaded against a different target module" do
    prog = Program.new(Prog)
    encoded = Artifact.encode(prog)

    assert {:error, %Invalid.Configuration{key: :target_module, reason: :module_mismatch} = exc} =
             Artifact.decode(WrongProg, encoded)

    assert exc.value == %{target: WrongProg, on_disk: Prog}
  end

  test "Source.Module.from_artifact_blob/1 rejects non-Dsxir modules with Invalid.Module" do
    assert_raise Invalid.Module, fn ->
      Dsxir.Program.Source.Module.from_artifact_blob("Elixir.Enum")
    end

    exc =
      try do
        Dsxir.Program.Source.Module.from_artifact_blob("Elixir.Enum")
        nil
      rescue
        e in Invalid.Module -> e
      end

    assert %Invalid.Module{module: Enum, reason: :not_a_dsxir_module} = exc
  end

  test "v2 runtime artifact referencing an unknown atom raises Invalid.Configuration" do
    json = """
    {
      "format_version": "2",
      "source_kind": "runtime",
      "source": {
        "id": "runtime/unknown_atom",
        "version": "0000000000000000000000000000000000000000000000000000000000000000",
        "inputs": [{"name": "q", "type": "string"}],
        "outputs": [{"name": "a", "type": "string"}],
        "nodes": [
          {
            "name": "zzz_definitely_not_a_loaded_atom_98765",
            "impl": "Elixir.Dsxir.Predictor.Predict",
            "signature": "Elixir.Dsxir.Test.Fixtures.AnswerQuestion"
          }
        ],
        "edges": [],
        "metadata": {}
      },
      "predictors": {},
      "metadata": {}
    }
    """

    exc =
      try do
        Artifact.decode_and_hydrate(json)
        flunk("expected Invalid.Configuration with :atom_not_loaded")
      rescue
        e in Invalid.Configuration -> e
      end

    assert exc.reason == :atom_not_loaded
  end
end
