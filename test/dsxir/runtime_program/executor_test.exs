defmodule Dsxir.RuntimeProgram.ExecutorTest do
  use ExUnit.Case, async: true

  alias Dsxir.Errors.Framework
  alias Dsxir.Errors.Runtime
  alias Dsxir.Prediction
  alias Dsxir.Program
  alias Dsxir.RuntimeProgram
  alias Dsxir.RuntimeProgram.Edge
  alias Dsxir.RuntimeProgram.Executor
  alias Dsxir.RuntimeProgram.FieldSpec
  alias Dsxir.RuntimeProgram.Node, as: RPNode
  alias Dsxir.Test.Fixtures.AnswerQuestion
  alias Dsxir.Test.Fixtures.DiamondABCD
  alias Dsxir.Test.Fixtures.LinearABC
  alias Dsxir.Test.Fixtures.ScriptedLM

  setup do
    ScriptedLM.clear_script()
    on_exit(&ScriptedLM.clear_script/0)
    :ok
  end

  defp linear_rp(opts \\ []) do
    guards = Keyword.get(opts, :guards, %{})

    %RuntimeProgram{
      id: "test/linear",
      version: <<0::256>>,
      inputs: [%FieldSpec{name: :question, type: :string}],
      outputs: [%FieldSpec{name: :answer, type: :string}],
      nodes: [
        node_with_guard(:a, Map.get(guards, :a)),
        node_with_guard(:b, Map.get(guards, :b)),
        node_with_guard(:c, Map.get(guards, :c))
      ],
      edges: [
        %Edge{from: {:program_input, :question}, to: {:node, :a, :question}},
        %Edge{from: {:node, :a, :answer}, to: {:node, :b, :question}},
        %Edge{from: {:node, :b, :answer}, to: {:node, :c, :question}},
        %Edge{from: {:node, :c, :answer}, to: {:program_output, :answer}}
      ]
    }
  end

  defp diamond_rp(opts \\ []) do
    guards = Keyword.get(opts, :guards, %{})
    fan_in_kind = Keyword.get(opts, :fan_in_kind, :required)

    %RuntimeProgram{
      id: "test/diamond",
      version: <<0::256>>,
      inputs: [%FieldSpec{name: :question, type: :string}],
      outputs: [%FieldSpec{name: :answer, type: :string}],
      nodes: [
        node_with_guard(:a, Map.get(guards, :a)),
        node_with_guard(:b, Map.get(guards, :b)),
        node_with_guard(:c, Map.get(guards, :c)),
        node_with_guard(:d, Map.get(guards, :d))
      ],
      edges: [
        %Edge{from: {:program_input, :question}, to: {:node, :a, :question}},
        %Edge{from: {:node, :a, :answer}, to: {:node, :b, :question}},
        %Edge{from: {:node, :a, :answer}, to: {:node, :c, :question}},
        %Edge{from: {:node, :b, :answer}, to: {:node, :d, :question}, kind: :required},
        %Edge{from: {:node, :c, :answer}, to: {:node, :d, :question}, kind: fan_in_kind},
        %Edge{from: {:node, :d, :answer}, to: {:program_output, :answer}}
      ]
    }
  end

  defp node_with_guard(name, nil),
    do: %RPNode{name: name, impl: ScriptedLM, signature: AnswerQuestion}

  defp node_with_guard(name, %Dsxir.Predicate.AST{} = ast),
    do: %RPNode{
      name: name,
      impl: ScriptedLM,
      signature: AnswerQuestion,
      guard: %Dsxir.Predicate.Source{source: ast.source, ast: ast}
    }

  defp guard_ast(source) do
    {:ok, ast} = Dsxir.Predicate.parse(source)
    ast
  end

  defp attach_skip_handler(tag) do
    ref = make_ref()

    :telemetry.attach(
      {tag, ref},
      [:dsxir, :runtime_program, :skipped],
      &Dsxir.Test.TelemetryHandler.forward/4,
      %{parent: self(), tag: tag}
    )

    on_exit(fn -> :telemetry.detach({tag, ref}) end)
    :ok
  end

  describe "linear chain" do
    test "threads outputs in topological order and returns the final answer" do
      ScriptedLM.install_script(%{
        a: %{answer: "from-a"},
        b: %{answer: "from-b"},
        c: %{answer: "from-c"}
      })

      prog = Program.new(LinearABC)
      rp = linear_rp()

      assert {%Program{} = _prog2, %Prediction{fields: %{answer: "from-c"}, skipped: nil}} =
               Executor.execute(rp, prog, %{question: "hi"})
    end
  end

  describe "diamond fan-in" do
    test "all four nodes execute when no guards fail; final output flows through d" do
      ScriptedLM.install_script(%{
        a: %{answer: "A"},
        b: %{answer: "B"},
        c: %{answer: "C"},
        d: %{answer: "D"}
      })

      prog = Program.new(DiamondABCD)
      rp = diamond_rp()

      assert {%Program{}, %Prediction{fields: %{answer: "D"}, skipped: nil}} =
               Executor.execute(rp, prog, %{question: "hi"})
    end

    test "optional fan-in: c skipped marks d as degraded" do
      attach_skip_handler(:diamond_optional)

      ScriptedLM.install_script(%{
        a: %{answer: "A"},
        b: %{answer: "B"},
        d: %{answer: "D"}
      })

      guard_false = guard_ast("a.answer == \"never-match\"")

      rp = diamond_rp(fan_in_kind: :optional, guards: %{c: guard_false})
      prog = Program.new(DiamondABCD)

      prior = Dsxir.Trace.start()

      try do
        assert {%Program{}, %Prediction{fields: %{answer: "D"}, skipped: nil}} =
                 Executor.execute(rp, prog, %{question: "hi"})

        trace = Dsxir.Trace.stop(prior)
        d_entry = Enum.find(trace, &(&1.predictor == :d))
        assert d_entry.degraded == true

        assert_received {:diamond_optional, [:dsxir, :runtime_program, :skipped], %{},
                         %{node: :c, reason: :guard_false}}
      after
        if Dsxir.Trace.active?(), do: Dsxir.Trace.stop(prior)
      end
    end
  end

  describe "skip cascade" do
    test "required upstream skip propagates downstream and emits telemetry for both" do
      attach_skip_handler(:cascade)

      ScriptedLM.install_script(%{a: %{answer: "A"}})

      guard_false_b = guard_ast("a.answer == \"nope\"")

      rp = linear_rp(guards: %{b: guard_false_b})
      prog = Program.new(LinearABC)

      assert_raise Runtime.SkippedOutputs, fn ->
        Executor.execute(rp, prog, %{question: "hi"})
      end

      assert_received {:cascade, [:dsxir, :runtime_program, :skipped], %{},
                       %{node: :b, reason: :guard_false}}

      assert_received {:cascade, [:dsxir, :runtime_program, :skipped], %{},
                       %{node: :c, reason: :upstream_required_skipped}}
    end
  end

  describe "on_skip policy" do
    test ":raise (default) raises SkippedOutputs with the skipped names" do
      ScriptedLM.install_script(%{a: %{answer: "A"}})

      guard_false_b = guard_ast("a.answer == \"nope\"")
      rp = linear_rp(guards: %{b: guard_false_b})
      prog = Program.new(LinearABC)

      err =
        try do
          Executor.execute(rp, prog, %{question: "hi"})
          flunk("expected Runtime.SkippedOutputs")
        rescue
          e in Runtime.SkippedOutputs -> e
        end

      assert err.skipped == [:answer]
    end

    test ":tagged_tuple returns {:partial, %Prediction{skipped: [...]}}" do
      ScriptedLM.install_script(%{a: %{answer: "A"}})

      guard_false_b = guard_ast("a.answer == \"nope\"")
      rp = linear_rp(guards: %{b: guard_false_b})
      prog = Program.new(LinearABC)

      assert {%Program{}, {:partial, %Prediction{skipped: [:answer]} = pred}} =
               Executor.execute(rp, prog, %{question: "hi"}, on_skip: :tagged_tuple)

      assert pred.fields[:answer] == nil
    end

    test ":nil returns a %Prediction{skipped: [...]} with nil-valued fields" do
      ScriptedLM.install_script(%{a: %{answer: "A"}})

      guard_false_b = guard_ast("a.answer == \"nope\"")
      rp = linear_rp(guards: %{b: guard_false_b})
      prog = Program.new(LinearABC)

      assert {%Program{}, %Prediction{skipped: [:answer]} = pred} =
               Executor.execute(rp, prog, %{question: "hi"}, on_skip: nil)

      assert pred.fields[:answer] == nil
    end

    test "unknown on_skip value raises ArgumentError with a clear message" do
      ScriptedLM.install_script(%{a: %{answer: "A"}, b: %{answer: "B"}, c: %{answer: "C"}})
      rp = linear_rp()
      prog = Program.new(LinearABC)

      err =
        assert_raise ArgumentError, fn ->
          Executor.execute(rp, prog, %{question: "hi"}, on_skip: :nonsense)
        end

      assert err.message =~ "invalid on_skip option"
      assert err.message =~ ":nonsense"
    end
  end

  describe "predicate runtime failure" do
    test "raises Runtime.PredicateError when guard evaluation fails at runtime" do
      ScriptedLM.install_script(%{a: %{answer: 42}})

      bad_guard = guard_ast("a.answer == \"text\"")
      rp = linear_rp(guards: %{b: bad_guard})
      prog = Program.new(LinearABC)

      err =
        try do
          Executor.execute(rp, prog, %{question: "hi"})
          flunk("expected Runtime.PredicateError")
        rescue
          e in Runtime.PredicateError -> e
        end

      assert err.node == :b
    end
  end

  describe "framework invariants" do
    test "missing program input raises Framework.MissingInput" do
      ScriptedLM.install_script(%{a: %{answer: "A"}})

      rp = linear_rp()
      prog = Program.new(LinearABC)

      assert_raise Framework.MissingInput, fn ->
        Executor.execute(rp, prog, %{})
      end
    end

    test "cycle bypassing validator raises Framework.CycleDetected (not MatchError)" do
      rp = linear_rp()

      cyclic_edges =
        rp.edges ++
          [
            %Edge{
              from: {:node, :c, :answer},
              to: {:node, :a, :question},
              kind: :required
            }
          ]

      rp = %{rp | edges: cyclic_edges}
      prog = Program.new(LinearABC)

      err =
        try do
          Executor.execute(rp, prog, %{question: "hi"})
          flunk("expected Framework.CycleDetected")
        rescue
          e in Framework.CycleDetected -> e
        end

      assert is_list(err.nodes)
      assert :a in err.nodes
      assert :b in err.nodes
      assert :c in err.nodes
    end
  end
end
