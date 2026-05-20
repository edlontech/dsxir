defmodule Dsxir.Program.SourceParameterizedTest do
  @moduledoc """
  Parameterized contract suite. Both Source implementations
  (`Dsxir.Program.Source.Module` and `Dsxir.Program.Source.RuntimeProgram`)
  are exercised against the same predictor name set (`:answer`) and the
  same signature (`Dsxir.Test.Fixtures.QA.Sig`) so each behaviour callback
  is asserted identically for both source kinds.
  """

  use ExUnit.Case, async: true

  alias Dsxir.Prediction
  alias Dsxir.Program
  alias Dsxir.Program.Source
  alias Dsxir.Test.Fixtures.QAScripted
  alias Dsxir.Test.Fixtures.RuntimePrograms
  alias Dsxir.Test.Fixtures.ScriptedLM

  def build_module_source, do: Source.Module.new!(QAScripted)

  def build_runtime_source do
    %Source.RuntimeProgram{runtime_program: RuntimePrograms.equivalent_to_qa()}
  end

  @sources [
    {:module, &__MODULE__.build_module_source/0},
    {:runtime, &__MODULE__.build_runtime_source/0}
  ]

  setup do
    ScriptedLM.clear_script()
    on_exit(&ScriptedLM.clear_script/0)
    :ok
  end

  for {kind, factory} <- @sources do
    describe "#{kind} source" do
      setup do
        {:ok, src: unquote(factory).()}
      end

      test "predictors/1 returns the same name set as optimizable_sites/1", %{src: src} do
        pred_names = src |> Source.predictors() |> Enum.map(& &1.name) |> MapSet.new()
        site_names = src |> Source.optimizable_sites() |> Enum.map(& &1.name) |> MapSet.new()
        assert pred_names == site_names
      end

      test "signature_for/2 returns the same signature as the predictor decl", %{src: src} do
        for decl <- Source.predictors(src) do
          assert Source.signature_for(src, decl.name) == decl.signature
        end
      end

      test "identity/1 returns a valid 3-tuple", %{src: src} do
        assert {kind, _, _} = Source.identity(src)
        assert kind in [:module, :runtime]
      end

      test "Program.forward/3 produces a %Prediction{} given matching inputs", %{src: src} do
        ScriptedLM.install_script(%{answer: %{a: "scripted"}})

        prog = Program.new(src)

        assert {%Program{}, %Prediction{fields: %{a: "scripted"}}} =
                 Program.forward(prog, %{q: "hello?"})
      end

      test "to_artifact_blob/1 round-trips through Dsxir.Artifact.encode/decode", %{src: src} do
        prog = Program.new(src)
        encoded = Dsxir.Artifact.encode(prog)
        loaded = Dsxir.Artifact.decode_and_hydrate(encoded)
        assert Source.identity(loaded.source) == Source.identity(src)
      end
    end
  end
end
