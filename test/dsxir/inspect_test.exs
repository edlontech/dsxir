defmodule Dsxir.InspectTest do
  use ExUnit.Case, async: true

  alias Dsxir.Test.Fixtures.AnswerProgram
  alias Dsxir.Test.Fixtures.AnswerQuestion
  alias Dsxir.Test.Fixtures.ThreePredictors

  describe "Dsxir.Example" do
    test "renders inputs and labels separately" do
      ex = Dsxir.Example.new(%{q: "x", a: "y"}, input_keys: [:q])
      str = inspect(ex)

      assert str =~ ~r/^#Dsxir\.Example<inputs: %\{q: "x"\}, labels: %\{a: "y"\}>$/
    end
  end

  describe "Dsxir.Prediction" do
    test "renders fields inline without the struct map noise" do
      pred = Dsxir.Prediction.new(%{answer: "Paris", confidence: 0.9})
      str = inspect(pred)

      assert str =~ "#Dsxir.Prediction<"
      assert str =~ ~s(answer: "Paris")
      assert str =~ "confidence: 0.9"
      refute str =~ "completions:"
      refute str =~ "lm_usage:"
    end

    test "renders empty fields as an empty container" do
      assert inspect(Dsxir.Prediction.new(%{})) == "#Dsxir.Prediction<>"
    end
  end

  describe "Dsxir.Demo" do
    test "labeled demo renders kind + inner example" do
      ex = Dsxir.Example.new(%{q: "x", a: "y"}, input_keys: [:q])
      demo = Dsxir.Demo.labeled(ex)
      str = inspect(demo)

      assert str =~ ~r/^#Dsxir\.Demo<:labeled, #Dsxir\.Example</
    end

    test "bootstrapped demo includes the source map" do
      ex = Dsxir.Example.new(%{q: "x", a: "y"}, input_keys: [:q])
      demo = Dsxir.Demo.bootstrapped(ex, %{round: 1, example_index: 4})
      str = inspect(demo)

      assert str =~ "#Dsxir.Demo<:bootstrapped, source:"
      assert str =~ "round: 1"
      assert str =~ "example_index: 4"
    end
  end

  describe "Dsxir.Primitives.History" do
    test "renders messages compactly with role: content pairs" do
      h =
        Dsxir.Primitives.History.new()
        |> Dsxir.Primitives.History.push(:user, "Hi")
        |> Dsxir.Primitives.History.push(:assistant, "Hello")

      str = inspect(h)

      assert str =~ "#Dsxir.Primitives.History<"
      assert str =~ ~s(user: "Hi")
      assert str =~ ~s(assistant: "Hello")
    end

    test "empty conversation renders as an empty container" do
      assert inspect(Dsxir.Primitives.History.new()) == "#Dsxir.Primitives.History<>"
    end
  end

  describe "Dsxir.Primitives.Tool" do
    test "function field is filtered, other fields render normally" do
      tool =
        Dsxir.Primitives.Tool.new(
          name: "calc",
          description: "evaluate",
          parameters: Zoi.object(%{expression: Zoi.string()}),
          function: fn _ -> "ok" end
        )

      str = inspect(tool)

      assert str =~ ~s(name: "calc")
      refute str =~ "function:"
    end
  end

  describe "Dsxir.Signature.Compiled" do
    test "renders an arrow form between input and output names" do
      {:ok, sig} = Dsxir.Signature.from_string("question, context -> answer, confidence")
      str = inspect(sig)

      assert str == "#Dsxir.Signature.Compiled<question, context -> answer, confidence>"
    end
  end

  describe "Dsxir.Signature.Field" do
    test "hides spark metadata noise" do
      [field | _] = Dsxir.Signature.Info.signature(AnswerQuestion)
      str = inspect(field)

      refute str =~ "__spark_metadata__"
      assert str =~ "name: :question"
    end
  end

  describe "Dsxir.Module.PredictorDecl" do
    test "hides spark metadata noise" do
      [decl | _] = Dsxir.Module.Info.module(AnswerProgram)
      str = inspect(decl)

      refute str =~ "__spark_metadata__"
      assert str =~ "name: :answer"
    end
  end

  describe "Dsxir.Predictor.ReAct.State" do
    test "summarises iter, done?, trajectory length" do
      state = %Dsxir.Predictor.ReAct.State{iter: 3, done?: true, trajectory: [%{}, %{}]}

      assert inspect(state) ==
               "#Dsxir.Predictor.ReAct.State<iter: 3, done?: true, trajectory: 2 step(s)>"
    end
  end

  describe "Dsxir.Program.State" do
    test "shows demo count, omits unset overrides" do
      assert inspect(%Dsxir.Program.State{}) == "#Dsxir.Program.State<demos: 0>"
    end

    test "shows overrides when present" do
      state = %Dsxir.Program.State{
        demos: [1, 2, 3],
        instructions_override: "override",
        signature_override: AnswerQuestion
      }

      str = inspect(state)
      assert str =~ "demos: 3"
      assert str =~ "instructions_override?: true"
      assert str =~ "signature_override: " <> inspect(AnswerQuestion)
    end
  end

  describe "Dsxir.Program" do
    test "shows module plus per-predictor demo counts" do
      prog = Dsxir.Program.new(ThreePredictors)
      str = inspect(prog)

      assert str =~ "#Dsxir.Program<"
      assert str =~ inspect(ThreePredictors)
      assert str =~ "a: 0 demo(s)"
      assert str =~ "b: 0 demo(s)"
      assert str =~ "c: 0 demo(s)"
    end
  end

  describe "Dsxir.CallContext" do
    test "shows predictor, signature, input keys" do
      ctx =
        Dsxir.CallContext.new(
          predictor: :answer,
          signature: AnswerQuestion,
          inputs: %{question: "hi"},
          program: Dsxir.Program.new(AnswerProgram)
        )

      str = inspect(ctx)

      assert str =~ "#Dsxir.CallContext<predictor: :answer"
      assert str =~ "signature: " <> inspect(AnswerQuestion)
      assert str =~ "inputs: [:question]"
    end
  end

  describe "Dsxir.Settings" do
    test "masks sensitive keys inside the lm config" do
      settings = %Dsxir.Settings{
        lm: {SomeLM, model: "gpt-4o", api_key: "sk-secret", token: "abc"},
        adapter: SomeAdapter
      }

      str = inspect(settings)

      assert str =~ "#Dsxir.Settings<"
      refute str =~ "sk-secret"
      refute str =~ "abc"
      assert str =~ "[FILTERED]"
      assert str =~ ~s(model: "gpt-4o")
    end

    test "nil lm renders without crashing" do
      assert inspect(%Dsxir.Settings{}) =~ "#Dsxir.Settings<"
    end
  end

  describe "Dsxir.Evaluate" do
    test "summarises the runner config" do
      ev = %Dsxir.Evaluate{devset: [1, 2, 3], num_threads: 4, max_errors: 7}

      assert inspect(ev) ==
               "#Dsxir.Evaluate<devset: 3, num_threads: 4, max_errors: 7>"
    end
  end

  describe "Dsxir.EvaluationResult" do
    test "summarises score, total, errors" do
      result = %Dsxir.EvaluationResult{
        score: 87.5,
        results: [1, 2, 3, 4],
        errors: %{count: 1, by_class: %{lm: 1}}
      }

      str = inspect(result)

      assert str =~ "#Dsxir.EvaluationResult<score: 87.5"
      assert str =~ "total: 4"
      assert str =~ "count: 1"
    end
  end

  describe "Dsxir.History" do
    test "hides the opaque counter ref" do
      state = %Dsxir.History{
        counter_ref: :counters.new(1, [:atomics]),
        max_size: 100,
        trim_batch: 10
      }

      str = inspect(state)

      refute str =~ "counter_ref"
      assert str =~ "max_size: 100"
      assert str =~ "trim_batch: 10"
    end
  end

  describe "Dsxir.Retrieval.InMemory" do
    test "summarises doc count, omits raw vectors" do
      idx = %Dsxir.Retrieval.InMemory{
        embedder: %Dsxir.Retrieval.Embedder{},
        docs: ["a", "b"],
        vectors: [[0.1, 0.2], [0.3, 0.4]]
      }

      str = inspect(idx)

      assert str =~ "#Dsxir.Retrieval.InMemory<2 doc(s)"
      refute str =~ "0.1"
      refute str =~ "0.3"
    end
  end
end
