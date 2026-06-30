defmodule Dsxir.Optimizer.SIMBA.Strategy.AppendDemoTest do
  use ExUnit.Case, async: true

  alias Dsxir.Demo
  alias Dsxir.Optimizer.SIMBA.Strategy.AppendDemo
  alias Dsxir.Prediction
  alias Dsxir.Program
  alias Dsxir.Test.Fixtures.QA
  alias Dsxir.Trace.Entry

  defp make_program(predictor_names) do
    Program.new(QA.Prog, predictor_names)
  end

  defp make_entry(predictor, inputs, output_fields) do
    %Entry{
      predictor: predictor,
      inputs: inputs,
      prediction: Prediction.new(output_fields),
      demos: []
    }
  end

  defp make_bucket(trace, score) do
    record = %{score: score, trace: trace, prediction: nil, example: nil, metadata: nil}
    %{records: [record], max_to_min_gap: 0.0, max_score: score, max_to_avg_gap: 0.0}
  end

  defp ctx(batch_p10, maxlen \\ 100_000) do
    %{batch_p10: batch_p10, batch_p90: 1.0, demo_input_field_maxlen: maxlen}
  end

  describe "apply/3 skip guard" do
    test "returns :skip when top.score equals batch_p10" do
      program = make_program([:pred_a])
      trace = [make_entry(:pred_a, %{q: "hello"}, %{a: "world"})]
      bucket = make_bucket(trace, 0.5)

      assert :skip == AppendDemo.apply(bucket, program, ctx(0.5))
    end

    test "returns :skip when top.score is below batch_p10" do
      program = make_program([:pred_a])
      trace = [make_entry(:pred_a, %{q: "hello"}, %{a: "world"})]
      bucket = make_bucket(trace, 0.3)

      assert :skip == AppendDemo.apply(bucket, program, ctx(0.5))
    end

    test "proceeds when top.score is strictly above batch_p10" do
      program = make_program([:pred_a])
      trace = [make_entry(:pred_a, %{q: "hello"}, %{a: "world"})]
      bucket = make_bucket(trace, 0.6)

      assert {:ok, _} = AppendDemo.apply(bucket, program, ctx(0.5))
    end
  end

  describe "apply/3 demo appending" do
    test "appends exactly one demo per predictor in trace" do
      program = make_program([:pred_a, :pred_b])

      trace = [
        make_entry(:pred_a, %{q: "hello"}, %{a: "world"}),
        make_entry(:pred_b, %{q: "foo"}, %{a: "bar"})
      ]

      bucket = make_bucket(trace, 0.9)

      {:ok, updated} = AppendDemo.apply(bucket, program, ctx(0.5))

      assert length(Program.get_state(updated, :pred_a).demos) == 1
      assert length(Program.get_state(updated, :pred_b).demos) == 1
    end

    test "last demo wins when trace visits the same predictor more than once" do
      program = make_program([:pred_a])

      trace = [
        make_entry(:pred_a, %{q: "first"}, %{a: "first_answer"}),
        make_entry(:pred_a, %{q: "second"}, %{a: "second_answer"})
      ]

      bucket = make_bucket(trace, 0.9)

      {:ok, updated} = AppendDemo.apply(bucket, program, ctx(0.5))

      state = Program.get_state(updated, :pred_a)
      assert length(state.demos) == 1
      [%Demo{example: ex}] = state.demos
      assert ex.data.q == "second"
      assert ex.data.a == "second_answer"
    end

    test "built demo is :bootstrapped kind with :append_demo strategy source" do
      program = make_program([:pred_a])
      trace = [make_entry(:pred_a, %{q: "hello"}, %{a: "world"})]
      bucket = make_bucket(trace, 0.9)

      {:ok, updated} = AppendDemo.apply(bucket, program, ctx(0.5))

      [demo] = Program.get_state(updated, :pred_a).demos
      assert demo.kind == :bootstrapped
      assert demo.source == %{strategy: :append_demo}
    end

    test "example marks entry input keys as inputs and output fields as labels" do
      program = make_program([:pred_a])
      trace = [make_entry(:pred_a, %{q: "hello"}, %{a: "world"})]
      bucket = make_bucket(trace, 0.9)

      {:ok, updated} = AppendDemo.apply(bucket, program, ctx(0.5))

      [%Demo{example: ex}] = Program.get_state(updated, :pred_a).demos
      assert Dsxir.Example.inputs(ex) == %{q: "hello"}
      assert Dsxir.Example.labels(ex) == %{a: "world"}
    end
  end

  describe "apply/3 input truncation" do
    test "truncates input field values exceeding demo_input_field_maxlen" do
      program = make_program([:pred_a])
      long_value = String.duplicate("x", 20)
      trace = [make_entry(:pred_a, %{q: long_value}, %{a: "short"})]
      bucket = make_bucket(trace, 0.9)

      {:ok, updated} = AppendDemo.apply(bucket, program, ctx(0.5, 5))

      [%Demo{example: ex}] = Program.get_state(updated, :pred_a).demos
      assert String.starts_with?(ex.data.q, "xxxxx")
      assert String.contains?(ex.data.q, "\n\t\t... <TRUNCATED FOR BREVITY>")
    end

    test "does not truncate values within the maxlen limit" do
      program = make_program([:pred_a])
      trace = [make_entry(:pred_a, %{q: "short"}, %{a: "answer"})]
      bucket = make_bucket(trace, 0.9)

      {:ok, updated} = AppendDemo.apply(bucket, program, ctx(0.5, 100))

      [%Demo{example: ex}] = Program.get_state(updated, :pred_a).demos
      assert ex.data.q == "short"
    end

    test "does not truncate when value length exactly equals maxlen" do
      program = make_program([:pred_a])
      value = String.duplicate("y", 10)
      trace = [make_entry(:pred_a, %{q: value}, %{a: "answer"})]
      bucket = make_bucket(trace, 0.9)

      {:ok, updated} = AppendDemo.apply(bucket, program, ctx(0.5, 10))

      [%Demo{example: ex}] = Program.get_state(updated, :pred_a).demos
      assert ex.data.q == value
    end

    test "only truncates input fields, not output fields" do
      program = make_program([:pred_a])
      long_output = String.duplicate("z", 20)
      trace = [make_entry(:pred_a, %{q: "input"}, %{a: long_output})]
      bucket = make_bucket(trace, 0.9)

      {:ok, updated} = AppendDemo.apply(bucket, program, ctx(0.5, 5))

      [%Demo{example: ex}] = Program.get_state(updated, :pred_a).demos
      assert ex.data.q == "input"
      assert ex.data.a == long_output
    end
  end
end
