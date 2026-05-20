defmodule Dsxir.Optimizer.GEPA.Operators.MutateDemos do
  @moduledoc """
  Single-parent operator with no LM call. Picks one predictor uniformly,
  picks a different demo bundle from the demo table for it, and returns a
  delta swapping that predictor's `demo_bundle_refs[name]`. Falls back to
  re-using the same bundle if only one bundle is available for the chosen
  predictor.
  """

  @behaviour Dsxir.Optimizer.GEPA.Operators

  alias Dsxir.Optimizer.GEPA.Delta
  alias Dsxir.Optimizer.GEPA.Individual

  @impl true
  def kind, do: :mutate_demos

  @impl true
  def parent_count, do: 1

  @impl true
  def apply(%Individual{} = parent, %{} = ctx) do
    {decl, rng1} = pick_decl(ctx.decls, ctx.rng)
    name = Map.fetch!(decl, :name)
    current_ref = Map.fetch!(parent.delta.demo_bundle_refs, name)
    {new_ref, _rng2} = pick_bundle(ctx.demo_table, name, current_ref, rng1)

    delta = %Delta{
      instructions: parent.delta.instructions,
      demo_bundle_refs: Map.put(parent.delta.demo_bundle_refs, name, new_ref)
    }

    {:ok, delta, 0}
  end

  defp pick_decl(decls, rng) when decls != [] do
    {r, rng2} = :rand.uniform_s(rng)
    idx = min(trunc(r * length(decls)), length(decls) - 1)
    {Enum.at(decls, idx), rng2}
  end

  defp pick_bundle(demo_table, predictor_name, current_ref, rng) do
    bundles = demo_table |> Map.fetch!(predictor_name) |> Map.keys()
    alternates = Enum.reject(bundles, &(&1 == current_ref))

    case alternates do
      [] ->
        {current_ref, rng}

      _ ->
        {r, rng2} = :rand.uniform_s(rng)
        idx = min(trunc(r * length(alternates)), length(alternates) - 1)
        {Enum.at(alternates, idx), rng2}
    end
  end
end
