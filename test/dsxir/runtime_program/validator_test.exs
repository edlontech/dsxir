defmodule Dsxir.RuntimeProgram.ValidatorTest do
  use ExUnit.Case, async: true

  alias Dsxir.Errors.Invalid
  alias Dsxir.Predicate
  alias Dsxir.RuntimeProgram
  alias Dsxir.RuntimeProgram.Edge
  alias Dsxir.RuntimeProgram.Node
  alias Dsxir.RuntimeProgram.Validator
  alias Dsxir.Test.Fixtures.RuntimePrograms

  test "happy path returns {:ok, rp} with guard ASTs attached" do
    rp = RuntimePrograms.minimal_valid()

    assert {:ok, %RuntimeProgram{} = ok_rp} = Validator.validate(rp)

    refine = Enum.find(ok_rp.nodes, &(&1.name == :refine))
    assert %Predicate.Source{ast: %Predicate.AST{}} = refine.guard
  end

  test "duplicate node names accumulate as one error per duplicate occurrence" do
    rp = RuntimePrograms.minimal_valid() |> RuntimePrograms.dup_node(:qa)

    assert {:error, %Invalid.RuntimeProgram{errors: errors}} = Validator.validate(rp)

    dup_errors = Enum.filter(errors, &(&1.code == :duplicate_node_name))
    assert [_ | _] = dup_errors
    assert Enum.all?(dup_errors, &(&1.path == [:nodes, :qa]))
  end

  test "unknown signature module reported with :unknown_signature code" do
    rp = RuntimePrograms.minimal_valid()
    [first | rest] = rp.nodes
    broken = %{first | signature: Dsxir.Test.NoSuchSignature}
    rp = %{rp | nodes: [broken | rest]}

    assert {:error, %Invalid.RuntimeProgram{errors: errors}} = Validator.validate(rp)
    assert Enum.any?(errors, &(&1.code == :unknown_signature))
  end

  test "unknown impl module reported with :unknown_impl code" do
    rp = RuntimePrograms.minimal_valid()
    [first | rest] = rp.nodes
    broken = %{first | impl: Dsxir.Test.NoSuchPredictor}
    rp = %{rp | nodes: [broken | rest]}

    assert {:error, %Invalid.RuntimeProgram{errors: errors}} = Validator.validate(rp)
    assert Enum.any?(errors, &(&1.code == :unknown_impl))
  end

  test "loaded non-predictor module rejected with :unknown_impl code" do
    rp = RuntimePrograms.minimal_valid()
    [first | rest] = rp.nodes
    Code.ensure_loaded!(IO)
    broken = %{first | impl: IO}
    rp = %{rp | nodes: [broken | rest]}

    assert {:error, %Invalid.RuntimeProgram{errors: errors}} = Validator.validate(rp)

    impl_err =
      Enum.find(errors, fn e ->
        e.code == :unknown_impl and List.starts_with?(e.path, [:nodes, first.name, :impl])
      end)

    assert impl_err,
           "expected an :unknown_impl error at [:nodes, #{inspect(first.name)}, :impl]; got #{inspect(errors)}"
  end

  test "edge to unknown node reports :edge_unknown_node" do
    rp = RuntimePrograms.minimal_valid() |> RuntimePrograms.break_edge_target(0)

    assert {:error, %Invalid.RuntimeProgram{errors: errors}} = Validator.validate(rp)

    assert Enum.any?(
             errors,
             &(&1.code == :edge_unknown_node and List.starts_with?(&1.path, [:edges, 0]))
           )
  end

  test "edge to unknown field on known node reports :edge_unknown_field" do
    rp = RuntimePrograms.minimal_valid()

    edges =
      List.update_at(rp.edges, 0, fn %Edge{} = e ->
        %{e | to: {:node, :qa, :__nope__}}
      end)

    rp = %{rp | edges: edges}

    assert {:error, %Invalid.RuntimeProgram{errors: errors}} = Validator.validate(rp)
    assert Enum.any?(errors, &(&1.code == :edge_unknown_field))
  end

  test "program output without any inbound edge reports :program_output_unreachable" do
    rp = RuntimePrograms.minimal_valid()
    [_pi, _qa_to_refine, _refine_to_out] = rp.edges
    rp = %{rp | edges: Enum.take(rp.edges, 2)}

    assert {:error, %Invalid.RuntimeProgram{errors: errors}} = Validator.validate(rp)

    assert Enum.any?(
             errors,
             &(&1.code == :program_output_unreachable and
                 &1.path == [:outputs, :answer])
           )
  end

  test "cycle is detected and reported with all SCC node names" do
    rp = RuntimePrograms.minimal_valid()

    extra_edge = %Edge{
      from: {:node, :refine, :answer},
      to: {:node, :qa, :question},
      kind: :required
    }

    rp = %{rp | edges: rp.edges ++ [extra_edge]}

    assert {:error, %Invalid.RuntimeProgram{errors: errors}} = Validator.validate(rp)

    cycle = Enum.find(errors, &(&1.code == :cycle))
    assert cycle, "expected a :cycle error"
    assert is_list(cycle.scc)
    assert :qa in cycle.scc
    assert :refine in cycle.scc
  end

  test "dangling required input reported with :dangling_required_input" do
    rp = RuntimePrograms.minimal_valid()
    rp = %{rp | edges: tl(rp.edges)}

    assert {:error, %Invalid.RuntimeProgram{errors: errors}} = Validator.validate(rp)
    assert Enum.any?(errors, &(&1.code == :dangling_required_input))
  end

  test "phase 2 short-circuits per guard, not globally: parse error on A, type error on B" do
    rp = RuntimePrograms.minimal_valid()

    nodes =
      Enum.map(rp.nodes, fn
        %Node{name: :qa} = n ->
          %{n | guard: %Predicate.Source{source: "))) bad"}}

        %Node{name: :refine} = n ->
          %{n | guard: %Predicate.Source{source: "length(input.question) > \"abc\""}}
      end)

    rp = %{rp | nodes: nodes}

    assert {:error, %Invalid.RuntimeProgram{errors: errors}} = Validator.validate(rp)

    parse_errs = Enum.filter(errors, &(&1.code == :predicate_parse_error))
    type_errs = Enum.filter(errors, &(&1.code == :predicate_type_error))
    assert length(parse_errs) == 1
    assert length(type_errs) == 1
  end

  test "phase 1 errors do not suppress phase 2 errors" do
    rp =
      RuntimePrograms.minimal_valid()
      |> RuntimePrograms.break_edge_target(0)
      |> RuntimePrograms.break_guard_parse(:refine)

    assert {:error, %Invalid.RuntimeProgram{errors: errors}} = Validator.validate(rp)
    assert Enum.any?(errors, &(&1.code == :edge_unknown_node))
    assert Enum.any?(errors, &(&1.code == :predicate_parse_error))
  end

  test "phase 1 errors do not suppress phase 3 errors" do
    rp = RuntimePrograms.minimal_valid()

    extra_inputs = rp.inputs ++ [%Dsxir.RuntimeProgram.FieldSpec{name: :extra, type: "int"}]

    bad_edge = %Edge{
      from: {:program_input, :extra},
      to: {:node, :qa, :question},
      kind: :required
    }

    rp = %{rp | inputs: extra_inputs, edges: rp.edges ++ [bad_edge]}

    rp =
      rp
      |> RuntimePrograms.break_guard_parse(:refine)

    assert {:error, %Invalid.RuntimeProgram{errors: errors}} = Validator.validate(rp)
    assert Enum.any?(errors, &(&1.code == :edge_type_mismatch))
    assert Enum.any?(errors, &(&1.code == :predicate_parse_error))
  end

  test "edge type mismatch reported per edge" do
    rp = RuntimePrograms.minimal_valid()

    rp = %{
      rp
      | inputs: [%Dsxir.RuntimeProgram.FieldSpec{name: :question, type: "int"}]
    }

    assert {:error, %Invalid.RuntimeProgram{errors: errors}} = Validator.validate(rp)
    assert Enum.any?(errors, &(&1.code == :edge_type_mismatch))
  end

  test "message/1 formats all errors with [code] at path: message" do
    rp = RuntimePrograms.minimal_valid() |> RuntimePrograms.dup_node(:qa)
    {:error, err} = Validator.validate(rp)
    msg = Exception.message(err)
    assert msg =~ "[duplicate_node_name]"
    assert msg =~ "nodes/qa"
  end
end
