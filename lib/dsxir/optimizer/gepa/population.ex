defmodule Dsxir.Optimizer.GEPA.Population do
  @moduledoc """
  Opaque collection of `%Individual{}` preserving birth order. Lookup by id is
  O(1); iteration is birth-order stable (oldest first).
  """

  alias Dsxir.Optimizer.GEPA.Individual

  defstruct by_id: %{}, order: []

  @type id :: Individual.id()
  @type t :: %__MODULE__{
          by_id: %{id() => Individual.t()},
          order: [id()]
        }

  @doc "Creates a new population seeded with a single individual."
  @spec new(Individual.t()) :: t()
  def new(%Individual{} = seed) do
    %__MODULE__{by_id: %{seed.id => seed}, order: [seed.id]}
  end

  @doc "Appends `ind` to the population. No-op when `ind.id` already exists."
  @spec add(t(), Individual.t()) :: t()
  def add(%__MODULE__{} = pop, %Individual{id: id} = ind) do
    if Map.has_key?(pop.by_id, id) do
      pop
    else
      %{pop | by_id: Map.put(pop.by_id, id, ind), order: pop.order ++ [id]}
    end
  end

  @doc "Looks up an individual by id. Returns `nil` if unknown."
  @spec by_id(t(), id()) :: Individual.t() | nil
  def by_id(%__MODULE__{by_id: m}, id), do: Map.get(m, id)

  @doc "Returns members in birth order (oldest first)."
  @spec to_list(t()) :: [Individual.t()]
  def to_list(%__MODULE__{by_id: m, order: order}) do
    Enum.map(order, &Map.fetch!(m, &1))
  end

  @doc "Number of individuals in the population."
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{order: order}), do: length(order)

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%Dsxir.Optimizer.GEPA.Population{order: order}, _opts) do
      concat([
        "#Dsxir.Optimizer.GEPA.Population<size: ",
        Integer.to_string(length(order)),
        ">"
      ])
    end
  end
end
