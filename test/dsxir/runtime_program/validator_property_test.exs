defmodule Dsxir.RuntimeProgram.ValidatorPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Dsxir.Errors.Invalid
  alias Dsxir.RuntimeProgram.Validator
  alias Dsxir.Test.Fixtures.RuntimePrograms

  for atom <- [:qa, :refine, :question, :answer, :program_input, :program_output] do
    _ = atom
  end

  @mutators [:dup_node, :break_edge_target, :break_guard_parse]

  defp apply_mutations(rp, mutations) do
    Enum.reduce(mutations, rp, &apply_mutation/2)
  end

  defp apply_mutation(:dup_node, rp), do: RuntimePrograms.dup_node(rp, :qa)
  defp apply_mutation(:break_edge_target, rp), do: RuntimePrograms.break_edge_target(rp, 0)
  defp apply_mutation(:break_guard_parse, rp), do: RuntimePrograms.break_guard_parse(rp, :refine)

  defp mutation_subset_generator do
    gen all(flags <- StreamData.list_of(StreamData.boolean(), length: length(@mutators))) do
      @mutators
      |> Enum.zip(flags)
      |> Enum.filter(fn {_m, on} -> on end)
      |> Enum.map(fn {m, _} -> m end)
    end
  end

  property "N independent mistakes yield at least N errors" do
    check all(mutations <- mutation_subset_generator(), mutations != []) do
      rp = RuntimePrograms.minimal_valid() |> apply_mutations(mutations)

      assert {:error, %Invalid.RuntimeProgram{errors: errors}} = Validator.validate(rp)
      assert length(errors) >= length(mutations)

      codes =
        errors
        |> Enum.map(& &1.code)
        |> MapSet.new()

      for mutation <- mutations do
        expected = expected_code(mutation)

        assert expected in codes,
               "expected #{expected} for mutation #{mutation} in #{inspect(codes)}"
      end
    end
  end

  defp expected_code(:dup_node), do: :duplicate_node_name
  defp expected_code(:break_edge_target), do: :edge_unknown_node
  defp expected_code(:break_guard_parse), do: :predicate_parse_error
end
