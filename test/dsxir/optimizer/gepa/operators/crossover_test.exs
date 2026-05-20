defmodule Dsxir.Optimizer.GEPA.Operators.CrossoverTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Dsxir.Optimizer.GEPA.Delta
  alias Dsxir.Optimizer.GEPA.Individual
  alias Dsxir.Optimizer.GEPA.Operators.Crossover

  setup :set_mimic_global

  setup do
    Mimic.copy(Dsxir.LM.Sycophant)
    :ok
  end

  defmodule SigA do
    use Dsxir.Signature

    signature do
      instruction("A original")
      input(:x, :string)
      output(:y, :string)
    end
  end

  defp parent_a do
    delta = %Delta{
      instructions: %{a: "instr from A"},
      demo_bundle_refs: %{a: %{seed: 0, kind: :labeled}}
    }

    Individual.new(delta, [0.9, 0.1], ["good", "bad"], [], :seed, 0)
  end

  defp parent_b do
    delta = %Delta{
      instructions: %{a: "instr from B"},
      demo_bundle_refs: %{a: %{seed: 1, kind: :bootstrap}}
    }

    Individual.new(delta, [0.5, 0.5], ["ok", "ok"], [], :seed, 0)
  end

  defp ctx do
    %{
      reflective_lm: {Dsxir.LM.Sycophant, []},
      demo_table: %{a: %{%{seed: 0, kind: :labeled} => []}},
      decls: [%{name: :a, signature: SigA}],
      rng: :rand.seed_s(:exsplus, {1, 2, 3}),
      config: %{rollout_k_success: 1, rollout_k_fail: 1}
    }
  end

  test "happy path returns merged instruction with parent A's demo refs" do
    Mimic.expect(Dsxir.LM.Sycophant, :generate_text, fn _, _, _ ->
      {:ok, "hybrid", %{}}
    end)

    a = parent_a()
    b = parent_b()

    assert {:ok, %Delta{} = delta, 1} = Crossover.apply({a, b}, ctx())
    assert delta.instructions == %{a: "hybrid"}
    assert delta.demo_bundle_refs == a.delta.demo_bundle_refs
  end

  test "LM error wraps to GEPAOperatorFailed with reason :reflective_lm_failed" do
    err = %Dsxir.Errors.LM.RateLimited{model_id: "x", retry_after: nil}
    Mimic.stub(Dsxir.LM.Sycophant, :generate_text, fn _, _, _ -> {:error, err} end)

    a = parent_a()
    b = parent_b()

    assert {:error,
            %Dsxir.Errors.Framework.GEPAOperatorFailed{
              operator: :crossover,
              reason: :reflective_lm_failed,
              parent_error: ^err,
              parents: parents
            }} = Crossover.apply({a, b}, ctx())

    assert parents == [a.id, b.id]
  end

  test "proposer_calls == 1 on success" do
    Mimic.stub(Dsxir.LM.Sycophant, :generate_text, fn _, _, _ -> {:ok, "merged", %{}} end)

    {:ok, _delta, calls} = Crossover.apply({parent_a(), parent_b()}, ctx())
    assert calls == 1
  end
end
