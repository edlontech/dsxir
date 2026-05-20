defmodule Dsxir.Program.ForwardTest do
  use ExUnit.Case, async: true

  alias Dsxir.Errors.Runtime
  alias Dsxir.Prediction
  alias Dsxir.Program
  alias Dsxir.Test.Fixtures.LinearABC
  alias Dsxir.Test.Fixtures.RuntimePrograms
  alias Dsxir.Test.Fixtures.ScriptedLM

  setup do
    ScriptedLM.clear_script()
    on_exit(&ScriptedLM.clear_script/0)
    :ok
  end

  describe "Source.Module dispatch" do
    test "forward/3 delegates to the user-defined forward/2 on the module" do
      ScriptedLM.install_script(%{
        a: %{answer: "from-a"},
        b: %{answer: "from-b"},
        c: %{answer: "from-c"}
      })

      prog = Program.new(LinearABC)

      assert {%Program{}, %Prediction{fields: %{answer: "from-a"}}} =
               Program.forward(prog, %{question: "hi"})
    end

    test "forward/2 is a delegate to forward/3 with empty opts" do
      ScriptedLM.install_script(%{
        a: %{answer: "from-a"},
        b: %{answer: "from-b"},
        c: %{answer: "from-c"}
      })

      prog = Program.new(LinearABC)
      assert {%Program{}, %Prediction{}} = Program.forward(prog, %{question: "hi"}, [])
    end
  end

  describe "Source.RuntimeProgram dispatch" do
    test "forward/3 dispatches to the executor for a runtime-program source" do
      ScriptedLM.install_script(%{
        step1: %{answer: "intermediate"},
        step2: %{answer: "final"}
      })

      rp = RuntimePrograms.linear_chain()
      prog = Program.from_runtime(rp)

      assert {%Program{}, %Prediction{fields: %{answer: "final"}, skipped: nil}} =
               Program.forward(prog, %{question: "hi"})
    end

    test "on_skip: :raise raises SkippedOutputs end-to-end" do
      ScriptedLM.install_script(%{
        step1: %{answer: "anything"},
        step2: %{answer: "unreachable"}
      })

      rp = RuntimePrograms.with_guard_false_on_required_output()
      prog = Program.from_runtime(rp)

      assert_raise Runtime.SkippedOutputs, fn ->
        Program.forward(prog, %{question: "hi"}, on_skip: :raise)
      end
    end

    test "on_skip: :tagged_tuple returns {:partial, %Prediction{}}" do
      ScriptedLM.install_script(%{
        step1: %{answer: "anything"},
        step2: %{answer: "unreachable"}
      })

      rp = RuntimePrograms.with_guard_false_on_required_output()
      prog = Program.from_runtime(rp)

      assert {%Program{}, {:partial, %Prediction{skipped: [:answer]}}} =
               Program.forward(prog, %{question: "hi"}, on_skip: :tagged_tuple)
    end
  end

  describe "from_runtime/1" do
    test "builds a program whose predictors map covers every node" do
      rp = RuntimePrograms.linear_chain()
      prog = Program.from_runtime(rp)

      assert %Dsxir.Program.Source.RuntimeProgram{runtime_program: ^rp} = prog.source
      assert Map.keys(prog.predictors) |> Enum.sort() == [:step1, :step2]
      assert prog.predictors.step1 == %Dsxir.Program.State{}
      assert prog.predictors.step2 == %Dsxir.Program.State{}
    end
  end
end
