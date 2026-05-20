defmodule Dsxir.Optimizer.GEPA.Operators.MutateInstrTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Dsxir.Optimizer.GEPA.Delta
  alias Dsxir.Optimizer.GEPA.Individual
  alias Dsxir.Optimizer.GEPA.Operators.MutateInstr

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

  defp parent do
    delta = %Delta{
      instructions: %{a: "A original"},
      demo_bundle_refs: %{a: %{seed: 0, kind: :labeled}}
    }

    Individual.new(delta, [0.9, 0.1], ["good", "bad"], [], :seed, 0)
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

  test "happy path returns new delta with rewritten instruction" do
    Mimic.expect(Dsxir.LM.Sycophant, :generate_text, fn _, _, _ ->
      {:ok, "A rewritten", %{}}
    end)

    assert {:ok, %Delta{instructions: %{a: "A rewritten"}}, 1} =
             MutateInstr.apply(parent(), ctx())
  end

  test "LM error wraps to GEPAOperatorFailed" do
    err = %Dsxir.Errors.LM.RateLimited{model_id: "x", retry_after: nil}
    Mimic.stub(Dsxir.LM.Sycophant, :generate_text, fn _, _, _ -> {:error, err} end)

    assert {:error,
            %Dsxir.Errors.Framework.GEPAOperatorFailed{
              operator: :mutate_instr,
              reason: :reflective_lm_failed,
              parent_error: ^err
            }} = MutateInstr.apply(parent(), ctx())
  end

  test "demo_bundle_refs are not touched" do
    Mimic.stub(Dsxir.LM.Sycophant, :generate_text, fn _, _, _ -> {:ok, "x", %{}} end)

    {:ok, delta, _} = MutateInstr.apply(parent(), ctx())
    assert delta.demo_bundle_refs == parent().delta.demo_bundle_refs
  end
end
