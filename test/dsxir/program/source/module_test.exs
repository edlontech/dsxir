defmodule Dsxir.Program.Source.ModuleTest do
  use ExUnit.Case, async: true

  alias Dsxir.Program.Source
  alias Dsxir.Program.Source.Module, as: ModuleSource

  test "wraps a Dsxir.Module" do
    assert %ModuleSource{module: Dsxir.Test.Fixtures.QA.Prog} =
             ModuleSource.new!(Dsxir.Test.Fixtures.QA.Prog)
  end

  test "rejects non-Dsxir modules with Invalid.Module" do
    assert_raise Dsxir.Errors.Invalid.Module, fn ->
      ModuleSource.new!(Enum)
    end
  end

  test "predictors/1 returns a list of %PredictorDecl{}" do
    src = ModuleSource.new!(Dsxir.Test.Fixtures.QA.Prog)

    assert [%Dsxir.Program.PredictorDecl{name: _, impl: _, signature: _} | _] =
             Source.predictors(src)
  end

  test "signature_for/2 returns the declared signature" do
    src = ModuleSource.new!(Dsxir.Test.Fixtures.QA.Prog)
    assert Dsxir.Test.Fixtures.QA.Sig = Source.signature_for(src, :answer)
  end

  test "signature_for/2 raises on unknown predictor" do
    src = ModuleSource.new!(Dsxir.Test.Fixtures.QA.Prog)

    assert_raise Dsxir.Errors.Invalid.Module, fn ->
      Source.signature_for(src, :nonexistent)
    end
  end

  test "execute/4 returns nil to delegate to user forward/2" do
    src = ModuleSource.new!(Dsxir.Test.Fixtures.QA.Prog)
    prog = Dsxir.Program.new(Dsxir.Test.Fixtures.QA.Prog)
    assert nil == Source.execute(src, prog, %{q: "x"}, [])
  end

  test "identity/1 is {:module, mod, nil}" do
    src = ModuleSource.new!(Dsxir.Test.Fixtures.QA.Prog)
    assert {:module, Dsxir.Test.Fixtures.QA.Prog, nil} = Source.identity(src)
  end

  test "optimizable_sites/1 enumerates every predictor" do
    src = ModuleSource.new!(Dsxir.Test.Fixtures.QA.Prog)
    decl_names = Source.predictors(src) |> Enum.map(& &1.name) |> Enum.sort()
    site_names = Source.optimizable_sites(src) |> Enum.map(& &1.name) |> Enum.sort()
    assert decl_names == site_names
  end

  test "optimizable_sites/1 sets kind to :predictor" do
    src = ModuleSource.new!(Dsxir.Test.Fixtures.QA.Prog)

    assert Enum.all?(Source.optimizable_sites(src), fn site ->
             site.kind == :predictor
           end)
  end

  test "put_predictor_state/3 is identity on Source.Module" do
    src = ModuleSource.new!(Dsxir.Test.Fixtures.QA.Prog)
    assert src == Source.put_predictor_state(src, :answer, %Dsxir.Program.State{})
  end

  test "to_artifact_blob/1 returns the module name as a string" do
    src = ModuleSource.new!(Dsxir.Test.Fixtures.QA.Prog)
    assert Source.to_artifact_blob(src) == "Elixir.Dsxir.Test.Fixtures.QA.Prog"
  end

  test "Program.new/1 wraps a module atom into Source.Module" do
    %Dsxir.Program{source: source} = Dsxir.Program.new(Dsxir.Test.Fixtures.QA.Prog)
    assert %ModuleSource{module: Dsxir.Test.Fixtures.QA.Prog} = source
  end
end
