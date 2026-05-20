defmodule Dsxir.Optimizer.GEPA.DeltaTest do
  use ExUnit.Case, async: true

  alias Dsxir.Optimizer.GEPA.Delta
  alias Dsxir.Program

  defp seed_program do
    %Program{
      source: nil,
      predictors: %{
        a: %Program.State{demos: [], instructions_override: nil, signature_override: nil},
        b: %Program.State{demos: [], instructions_override: nil, signature_override: nil}
      },
      metadata: %{}
    }
  end

  test "apply_to overrides instructions and slots referenced demos" do
    bundle_ref = %{seed: 0, kind: :labeled}
    demo = %Dsxir.Demo{example: %Dsxir.Example{data: %{x: 1}}, kind: :labeled}
    demo_table = %{a: %{bundle_ref => [demo]}, b: %{bundle_ref => []}}

    delta = %Delta{
      instructions: %{a: "do a", b: "do b"},
      demo_bundle_refs: %{a: bundle_ref, b: bundle_ref}
    }

    compiled = Delta.apply_to(seed_program(), delta, demo_table)
    assert compiled.predictors.a.instructions_override == "do a"
    assert compiled.predictors.a.demos == [demo]
    assert compiled.predictors.b.demos == []
  end

  test "missing predictor in delta is silently skipped (defensive)" do
    bundle_ref = %{seed: 0, kind: :labeled}

    delta = %Delta{
      instructions: %{nonexistent: "x"},
      demo_bundle_refs: %{nonexistent: bundle_ref}
    }

    out = Delta.apply_to(seed_program(), delta, %{})
    assert out.predictors == seed_program().predictors
  end

  test "missing bundle_ref in demo_table raises KeyError" do
    delta = %Delta{
      instructions: %{a: "do a"},
      demo_bundle_refs: %{a: %{seed: 999, kind: :labeled}}
    }

    assert_raise KeyError, fn -> Delta.apply_to(seed_program(), delta, %{a: %{}}) end
  end
end
