defmodule Dsxir.ProgramTest do
  use ExUnit.Case, async: true

  defmodule SamplePipeline do
    use Dsxir.Module

    predictor :extract, Dsxir.Predictor.Predict, signature: Dsxir.Test.Fixtures.AnswerQuestion
    predictor :summarise, Dsxir.Predictor.Predict, signature: Dsxir.Test.Fixtures.AnswerQuestion

    def forward(prog, _inputs), do: {prog, %Dsxir.Prediction{}}
  end

  defmodule NotADsxirModule do
  end

  test "new/1 reads predictor names from a Dsxir.Module-built module" do
    prog = Dsxir.Program.new(SamplePipeline)
    assert prog.module == SamplePipeline
    assert Map.keys(prog.predictors) |> Enum.sort() == [:extract, :summarise]
    assert prog.predictors.extract == %Dsxir.Program.State{}
  end

  test "new/1 raises Invalid.Module for a non-Dsxir.Module module" do
    err =
      try do
        Dsxir.Program.new(NotADsxirModule)
      rescue
        e in Dsxir.Errors.Invalid.Module -> e
      end

    assert %Dsxir.Errors.Invalid.Module{
             module: NotADsxirModule,
             predictor: nil,
             reason: :not_a_dsxir_module
           } = err
  end

  test "new/2 accepts an explicit predictor-name list (no Dsxir.Module needed)" do
    prog = Dsxir.Program.new(NotADsxirModule, [:only])
    assert Map.keys(prog.predictors) == [:only]
  end

  test "get_state/2 returns the per-predictor State" do
    prog = Dsxir.Program.new(SamplePipeline)
    assert Dsxir.Program.get_state(prog, :extract) == %Dsxir.Program.State{}
  end

  test "get_state/2 raises Invalid.Module on unknown predictor with module breadcrumb" do
    prog = Dsxir.Program.new(SamplePipeline)

    err =
      try do
        Dsxir.Program.get_state(prog, :nonexistent)
      rescue
        e in Dsxir.Errors.Invalid.Module -> e
      end

    assert %Dsxir.Errors.Invalid.Module{
             module: SamplePipeline,
             predictor: :nonexistent,
             reason: :unknown_predictor
           } = err
  end

  test "put_state/3 replaces the per-predictor State" do
    prog = Dsxir.Program.new(SamplePipeline)
    updated = Dsxir.Program.put_state(prog, :extract, %Dsxir.Program.State{demos: [:a, :b]})
    assert Dsxir.Program.get_state(updated, :extract).demos == [:a, :b]
    assert Dsxir.Program.get_state(updated, :summarise) == %Dsxir.Program.State{}
  end
end
