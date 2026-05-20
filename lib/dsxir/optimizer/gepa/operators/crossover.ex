defmodule Dsxir.Optimizer.GEPA.Operators.Crossover do
  @moduledoc """
  Two-parent operator. Picks one predictor where the two parents differ in
  instruction text (falls back to a uniform random predictor if instructions
  are identical across all predictors). Asks the reflective LM to merge the
  two parents' instructions for that predictor. Demo bundle ref is inherited
  from parent A.
  """

  @behaviour Dsxir.Optimizer.GEPA.Operators

  alias Dsxir.Optimizer.GEPA.Delta
  alias Dsxir.Optimizer.GEPA.FeedbackPool
  alias Dsxir.Optimizer.GEPA.Individual
  alias Dsxir.Optimizer.GEPA.Proposer.Reflective

  @impl true
  def kind, do: :crossover

  @impl true
  def parent_count, do: 2

  @impl true
  def apply({%Individual{} = a, %Individual{} = b}, %{} = ctx) do
    {decl, _rng1} = pick_differing_decl(ctx.decls, a, b, ctx.rng)

    {rollouts_a, _rng2} =
      FeedbackPool.sample_rollouts(
        a,
        ctx.config.rollout_k_success,
        ctx.config.rollout_k_fail,
        ctx.rng
      )

    name = Map.fetch!(decl, :name)
    signature = Map.fetch!(decl, :signature)
    instr_a = Map.fetch!(a.delta.instructions, name)
    instr_b = Map.fetch!(b.delta.instructions, name)

    case Reflective.merge(instr_a, instr_b, rollouts_a, signature, ctx.reflective_lm) do
      {:ok, merged} ->
        delta = %Delta{
          instructions: Map.put(a.delta.instructions, name, merged),
          demo_bundle_refs: a.delta.demo_bundle_refs
        }

        {:ok, delta, 1}

      {:error, exc} ->
        {:error,
         %Dsxir.Errors.Framework.GEPAOperatorFailed{
           operator: :crossover,
           parents: [a.id, b.id],
           reason: :reflective_lm_failed,
           parent_error: exc
         }}
    end
  end

  defp pick_differing_decl(decls, a, b, rng) do
    differing =
      Enum.filter(decls, fn decl ->
        name = Map.fetch!(decl, :name)
        Map.fetch!(a.delta.instructions, name) != Map.fetch!(b.delta.instructions, name)
      end)

    pool = if differing == [], do: decls, else: differing
    {r, rng2} = :rand.uniform_s(rng)
    idx = min(trunc(r * length(pool)), length(pool) - 1)
    {Enum.at(pool, idx), rng2}
  end
end
