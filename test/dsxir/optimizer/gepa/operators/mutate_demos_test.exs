defmodule Dsxir.Optimizer.GEPA.Operators.MutateDemosTest do
  use ExUnit.Case, async: false

  alias Dsxir.Optimizer.GEPA.Delta
  alias Dsxir.Optimizer.GEPA.Individual
  alias Dsxir.Optimizer.GEPA.Operators.MutateDemos

  defmodule SigA do
    use Dsxir.Signature

    signature do
      instruction("A original")
      input(:x, :string)
      output(:y, :string)
    end
  end

  defp parent(refs) do
    delta = %Delta{
      instructions: %{a: "A", b: "B"},
      demo_bundle_refs: refs
    }

    Individual.new(delta, [0.5, 0.5], ["ok", "ok"], [], :seed, 0)
  end

  defp ctx(demo_table, decls, seed \\ {1, 2, 3}) do
    %{
      reflective_lm: {Dsxir.LM.Sycophant, []},
      demo_table: demo_table,
      decls: decls,
      rng: :rand.seed_s(:exsplus, seed),
      config: %{rollout_k_success: 1, rollout_k_fail: 1}
    }
  end

  test "swaps bundle ref to a different bundle when multiple are available" do
    bundle_a0 = %{seed: 0, kind: :labeled}
    bundle_a1 = %{seed: 1, kind: :labeled}
    bundle_a2 = %{seed: 2, kind: :bootstrap}
    bundle_b0 = %{seed: 0, kind: :labeled}
    bundle_b1 = %{seed: 1, kind: :bootstrap}

    demo_table = %{
      a: %{bundle_a0 => [], bundle_a1 => [], bundle_a2 => []},
      b: %{bundle_b0 => [], bundle_b1 => []}
    }

    decls = [%{name: :a, signature: SigA}]

    p = parent(%{a: bundle_a0, b: bundle_b0})

    {:ok, delta, calls} = MutateDemos.apply(p, ctx(demo_table, decls))

    assert calls == 0
    assert delta.instructions == p.delta.instructions
    assert delta.demo_bundle_refs.b == bundle_b0
    assert delta.demo_bundle_refs.a in [bundle_a1, bundle_a2]
    refute delta.demo_bundle_refs.a == bundle_a0
  end

  test "falls back to identity when only one bundle exists for the chosen predictor" do
    only = %{seed: 0, kind: :labeled}
    demo_table = %{a: %{only => []}, b: %{only => []}}
    decls = [%{name: :a, signature: SigA}]

    p = parent(%{a: only, b: only})

    {:ok, delta, 0} = MutateDemos.apply(p, ctx(demo_table, decls))

    assert delta.demo_bundle_refs == p.delta.demo_bundle_refs
    assert delta.instructions == p.delta.instructions
  end

  test "demo_bundle_refs structure preserved for predictors other than the mutated one" do
    bundle_a0 = %{seed: 0, kind: :labeled}
    bundle_a1 = %{seed: 1, kind: :labeled}
    bundle_b0 = %{seed: 0, kind: :labeled}
    bundle_b1 = %{seed: 1, kind: :bootstrap}

    demo_table = %{
      a: %{bundle_a0 => [], bundle_a1 => []},
      b: %{bundle_b0 => [], bundle_b1 => []}
    }

    decls = [%{name: :a, signature: SigA}]

    p = parent(%{a: bundle_a0, b: bundle_b0})

    {:ok, delta, _} = MutateDemos.apply(p, ctx(demo_table, decls))

    assert Map.keys(delta.demo_bundle_refs) |> Enum.sort() == [:a, :b]
    assert delta.demo_bundle_refs.b == bundle_b0
  end
end
