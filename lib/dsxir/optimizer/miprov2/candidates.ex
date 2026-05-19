defmodule Dsxir.Optimizer.MIPROv2.Candidates do
  @moduledoc """
  Builds the categorical search space for MIPROv2 and the lookup table that
  maps `{predictor_name, dim, index}` back to the actual instruction string or
  demo bundle.

  Each predictor contributes two categorical dimensions:

    * `{name, :instruction}` ranging over indices `0..N`, where index 0 is the
      current instruction (possibly `nil`) and indices `1..N` are proposed
      instruction strings.
    * `{name, :demos}` ranging over indices `0..M`, where index 0 is an empty
      demo bundle (`[]`) and indices `1..M` are candidate demo bundles.
  """

  alias Dsxir.Optimizer.Search.Sampler

  @type lookup :: %{
          {atom(), :instruction} => %{non_neg_integer() => String.t() | nil},
          {atom(), :demos} => %{non_neg_integer() => [Dsxir.Demo.t()]}
        }

  defstruct space: %{}, lookup: %{}

  @type t :: %__MODULE__{space: Sampler.space(), lookup: lookup()}

  @doc """
  Build the space and lookup from per-predictor proposed instruction lists and
  demo bundle lists.

  `current_instructions` — `%{predictor_name => current_instruction | nil}`.
  `proposed_instructions` — `%{predictor_name => [proposed_instruction]}`.
  `demo_bundles` — `%{predictor_name => [bundle]}` where each `bundle` is a
  list of `Dsxir.Demo.t()`.

  The current instruction (`nil` if not set) is prepended at index 0 of each
  predictor's instruction list; an empty demo bundle (`[]`) is prepended at
  index 0 of each predictor's demo list.
  """
  @spec build(
          current_instructions :: %{atom() => String.t() | nil},
          proposed_instructions :: %{atom() => [String.t()]},
          demo_bundles :: %{atom() => [[Dsxir.Demo.t()]]}
        ) :: t()
  def build(current_instructions, proposed_instructions, demo_bundles) do
    instruction_dims =
      for {predictor_name, proposed} <- proposed_instructions, into: %{} do
        current = Map.get(current_instructions, predictor_name)
        full = [current | proposed]
        indices = Enum.to_list(0..(length(full) - 1))

        key = {predictor_name, :instruction}
        lookup_entry = full |> Enum.with_index() |> Map.new(fn {v, i} -> {i, v} end)
        {key, {indices, lookup_entry}}
      end

    demo_dims =
      for {predictor_name, bundles} <- demo_bundles, into: %{} do
        full = [[] | bundles]
        indices = Enum.to_list(0..(length(full) - 1))

        key = {predictor_name, :demos}
        lookup_entry = full |> Enum.with_index() |> Map.new(fn {v, i} -> {i, v} end)
        {key, {indices, lookup_entry}}
      end

    dims = Map.merge(instruction_dims, demo_dims)

    space =
      for {key, {indices, _}} <- dims, into: %{} do
        {key, {:categorical, indices}}
      end

    lookup =
      for {key, {_, lookup_entry}} <- dims, into: %{} do
        {key, lookup_entry}
      end

    %__MODULE__{space: space, lookup: lookup}
  end

  @doc """
  Resolve a sampled config into a map of
  `predictor_name => %{instruction: string | nil, demos: [demo]}` using the
  lookup table built by `build/3`.
  """
  @spec resolve(t(), Sampler.config()) :: %{
          atom() => %{instruction: String.t() | nil, demos: [Dsxir.Demo.t()]}
        }
  def resolve(%__MODULE__{lookup: lookup}, config) do
    predictors =
      config
      |> Map.keys()
      |> Enum.map(fn {p, _} -> p end)
      |> Enum.uniq()

    Map.new(predictors, fn p ->
      i_idx = Map.fetch!(config, {p, :instruction})
      d_idx = Map.fetch!(config, {p, :demos})

      {p,
       %{
         instruction: lookup |> Map.fetch!({p, :instruction}) |> Map.fetch!(i_idx),
         demos: lookup |> Map.fetch!({p, :demos}) |> Map.fetch!(d_idx)
       }}
    end)
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%Dsxir.Optimizer.MIPROv2.Candidates{space: space}, _opts) do
      predictors =
        space
        |> Map.keys()
        |> Enum.map(fn {p, _} -> p end)
        |> Enum.uniq()
        |> length()

      concat([
        "#Dsxir.Optimizer.MIPROv2.Candidates<dims: ",
        Integer.to_string(map_size(space)),
        ", predictors: ",
        Integer.to_string(predictors),
        ">"
      ])
    end
  end
end
