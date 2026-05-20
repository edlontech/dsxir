defmodule Dsxir.Optimizer.GEPA.Operators.MutateInstr do
  @moduledoc """
  Single-parent operator. Picks one predictor uniformly at random; samples
  K_success + K_fail rollouts from the parent; asks the reflective LM to
  rewrite that predictor's instruction. Returns a new delta with all other
  predictors' instructions and demo refs unchanged from the parent.
  """

  @behaviour Dsxir.Optimizer.GEPA.Operators

  alias Dsxir.Optimizer.GEPA.Delta
  alias Dsxir.Optimizer.GEPA.FeedbackPool
  alias Dsxir.Optimizer.GEPA.Individual
  alias Dsxir.Optimizer.GEPA.Proposer.Reflective

  @impl true
  def kind, do: :mutate_instr

  @impl true
  def parent_count, do: 1

  @impl true
  def apply(%Individual{} = parent, %{} = ctx) do
    {decl, _rng1} = pick_decl(ctx.decls, ctx.rng)

    {rollouts, _rng2} =
      FeedbackPool.sample_rollouts(
        parent,
        ctx.config.rollout_k_success,
        ctx.config.rollout_k_fail,
        ctx.rng
      )

    name = Map.fetch!(decl, :name)
    signature = Map.fetch!(decl, :signature)
    current_instr = Map.fetch!(parent.delta.instructions, name)

    case Reflective.rewrite(
           current_instr,
           rollouts_for(rollouts, name),
           signature,
           ctx.reflective_lm
         ) do
      {:ok, new_instr} ->
        delta = %Delta{
          instructions: Map.put(parent.delta.instructions, name, new_instr),
          demo_bundle_refs: parent.delta.demo_bundle_refs
        }

        {:ok, delta, 1}

      {:error, exc} ->
        {:error,
         %Dsxir.Errors.Framework.GEPAOperatorFailed{
           operator: :mutate_instr,
           parents: [parent.id],
           reason: :reflective_lm_failed,
           parent_error: exc
         }}
    end
  end

  defp pick_decl(decls, rng) when decls != [] do
    {r, rng2} = :rand.uniform_s(rng)
    idx = min(trunc(r * length(decls)), length(decls) - 1)
    {Enum.at(decls, idx), rng2}
  end

  defp rollouts_for(rollouts, _predictor_name), do: rollouts
end
