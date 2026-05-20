defmodule Dsxir.Optimizer.GEPA.Delta do
  @moduledoc """
  Per-individual delta against the seed program. `apply_to/3` materializes a
  `%Dsxir.Program{}` from the seed by overriding each predictor's instruction
  and slotting the referenced demo bundle.
  """

  alias Dsxir.Program

  @enforce_keys [:instructions, :demo_bundle_refs]
  defstruct [:instructions, :demo_bundle_refs]

  @type bundle_ref :: %{seed: non_neg_integer(), kind: :labeled | :bootstrap}
  @type t :: %__MODULE__{
          instructions: %{atom() => String.t()},
          demo_bundle_refs: %{atom() => bundle_ref()}
        }

  @doc """
  Apply this delta to `seed`, looking up each predictor's demo bundle in
  `demo_table` keyed by `{predictor_name, bundle_ref}`.
  """
  @spec apply_to(Program.t(), t(), %{atom() => %{bundle_ref() => [Dsxir.Demo.t()]}}) ::
          Program.t()
  def apply_to(%Program{predictors: predictors} = seed, %__MODULE__{} = delta, demo_table) do
    new_predictors =
      Enum.reduce(delta.instructions, predictors, fn {name, instruction}, acc ->
        case Map.fetch(acc, name) do
          {:ok, state} ->
            ref = Map.fetch!(delta.demo_bundle_refs, name)
            demos = demo_for(demo_table, name, ref)
            Map.put(acc, name, %{state | instructions_override: instruction, demos: demos})

          :error ->
            acc
        end
      end)

    %{seed | predictors: new_predictors}
  end

  defp demo_for(demo_table, predictor_name, bundle_ref) do
    demo_table
    |> Map.fetch!(predictor_name)
    |> Map.fetch!(bundle_ref)
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%Dsxir.Optimizer.GEPA.Delta{} = delta, _opts) do
      concat([
        "#Dsxir.Optimizer.GEPA.Delta<instructions: ",
        Integer.to_string(map_size(delta.instructions)),
        ", demo_bundles: ",
        Integer.to_string(map_size(delta.demo_bundle_refs)),
        ">"
      ])
    end
  end
end
