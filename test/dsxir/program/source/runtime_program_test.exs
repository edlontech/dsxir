defmodule Dsxir.Program.Source.RuntimeProgramTest do
  use ExUnit.Case, async: true

  alias Dsxir.Prediction
  alias Dsxir.Program
  alias Dsxir.Program.Source
  alias Dsxir.Program.Source.RuntimeProgram, as: RPSource
  alias Dsxir.Test.Fixtures.RuntimePrograms
  alias Dsxir.Test.Fixtures.ScriptedLM

  setup do
    ScriptedLM.clear_script()
    on_exit(&ScriptedLM.clear_script/0)
    :ok
  end

  defp linear_source do
    %RPSource{runtime_program: RuntimePrograms.linear_chain()}
  end

  test "predictors/1 returns one %PredictorDecl{} per node" do
    src = linear_source()

    assert [
             %Dsxir.Program.PredictorDecl{name: :step1, impl: ScriptedLM},
             %Dsxir.Program.PredictorDecl{name: :step2, impl: ScriptedLM}
           ] = Source.predictors(src)
  end

  test "signature_for/2 returns the node's declared signature" do
    src = linear_source()
    assert Dsxir.Test.Fixtures.AnswerQuestion = Source.signature_for(src, :step1)
    assert Dsxir.Test.Fixtures.AnswerQuestion = Source.signature_for(src, :step2)
  end

  test "signature_for/2 with an unknown predictor raises with the program id as :module" do
    src = linear_source()

    assert_raise Dsxir.Errors.Invalid.Module, fn ->
      Source.signature_for(src, :nope)
    end

    err =
      try do
        Source.signature_for(src, :nope)
      rescue
        e -> e
      end

    assert %Dsxir.Errors.Invalid.Module{
             module: "test/linear_chain",
             predictor: :nope,
             reason: :unknown_predictor
           } = err
  end

  test "identity/1 returns {:runtime, id, version} with correct types" do
    src = linear_source()
    assert {:runtime, id, <<_::256>>} = Source.identity(src)
    assert is_binary(id)
    assert id == "test/linear_chain"
  end

  test "optimizable_sites/1 enumerates every node with kind :predictor" do
    src = linear_source()
    sites = Source.optimizable_sites(src)

    assert [
             %Dsxir.Program.OptimizableSite{name: :step1, kind: :predictor},
             %Dsxir.Program.OptimizableSite{name: :step2, kind: :predictor}
           ] = sites
  end

  test "put_predictor_state/3 is identity on Source.RuntimeProgram" do
    src = linear_source()
    assert src == Source.put_predictor_state(src, :step1, %Dsxir.Program.State{})
  end

  test "to_artifact_blob/1 returns a JSON-safe map carrying id, version, nodes, edges" do
    src = linear_source()
    blob = Source.to_artifact_blob(src)
    assert blob["id"] == "test/linear_chain"
    assert is_binary(blob["version"])
    assert is_list(blob["nodes"])
    assert is_list(blob["edges"])
  end

  test "execute/4 calls the Executor and returns {prog, %Prediction{}}" do
    ScriptedLM.install_script(%{
      step1: %{answer: "intermediate"},
      step2: %{answer: "final"}
    })

    src = linear_source()
    prog = Program.from_runtime(src.runtime_program)

    assert {%Program{}, %Prediction{fields: %{answer: "final"}, skipped: nil}} =
             Source.execute(src, prog, %{question: "hi"}, [])
  end
end
