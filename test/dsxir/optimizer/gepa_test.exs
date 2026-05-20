defmodule Dsxir.Optimizer.GEPATest do
  use ExUnit.Case, async: false
  use Mimic

  alias Dsxir.Metric.ScoreWithFeedback

  setup :set_mimic_global

  defmodule Sig1 do
    use Dsxir.Signature

    signature do
      instruction("Summarize.")
      input(:text, :string)
      output(:summary, :string)
    end
  end

  defmodule GepaProbe do
    use Dsxir.Module

    predictor(:summarize, Dsxir.Predictor.Predict, signature: Sig1)

    def forward(prog, %{text: t}) do
      {prog, p} = call(prog, :summarize, %{text: t})
      {prog, p}
    end
  end

  defp trainset do
    for i <- 1..6 do
      %Dsxir.Example{
        data: %{text: "text_#{i}", summary: "summary_#{i}"},
        input_keys: MapSet.new([:text])
      }
    end
  end

  defp metric do
    fn ex, pred, _trace ->
      summary = Map.get(pred.fields, :summary)
      hit = summary == ex.data.summary

      %ScoreWithFeedback{
        score: if(hit, do: 1.0, else: 0.0),
        feedback: if(hit, do: "ok", else: "wrong summary")
      }
    end
  end

  test "compile/4 produces a typed stats record and a compiled program" do
    Mimic.copy(Dsxir.LM.Sycophant)

    Mimic.stub(Dsxir.LM.Sycophant, :generate_text, fn _, _, _ ->
      {:ok, "improved instruction", %{}}
    end)

    program = Dsxir.Program.new(GepaProbe)

    Mimic.copy(Dsxir.Program)

    Mimic.stub(Dsxir.Program, :forward, fn prog, %{text: t} ->
      summary = "summary_" <> String.replace(t, "text_", "")
      {prog, %Dsxir.Prediction{fields: %{summary: summary}}}
    end)

    Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      {:ok, compiled, stats} =
        Dsxir.Optimizer.GEPA.compile(program, trainset(), metric(),
          auto: :light,
          num_trials: 3
        )

      assert compiled.metadata.compiled_with == Dsxir.Optimizer.GEPA
      assert is_float(stats.best_score)
      assert stats.population_size >= 2
      assert stats.frontier_size >= 1
      assert length(stats.trials) <= 3
    end)
  end

  test "compile/4 with non-zero :seed completes without crashing on demo lookup" do
    Mimic.copy(Dsxir.LM.Sycophant)

    Mimic.stub(Dsxir.LM.Sycophant, :generate_text, fn _, _, _ ->
      {:ok, "rewritten instruction", %{}}
    end)

    Mimic.copy(Dsxir.Program)

    Mimic.stub(Dsxir.Program, :forward, fn prog, %{text: t} ->
      summary = "summary_" <> String.replace(t, "text_", "")
      {prog, %Dsxir.Prediction{fields: %{summary: summary}}}
    end)

    program = Dsxir.Program.new(GepaProbe)

    Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      assert {:ok, _compiled, stats} =
               Dsxir.Optimizer.GEPA.compile(program, trainset(), metric(),
                 auto: :light,
                 num_trials: 2,
                 seed: 7
               )

      assert is_float(stats.best_score)
    end)
  end

  test "init_session validates :reflective_lm shape and returns Configuration error when nil" do
    program = Dsxir.Program.new(GepaProbe)

    Dsxir.context([lm: nil], fn ->
      assert {:error, %Dsxir.Errors.Invalid.Configuration{key: :reflective_lm, value: nil}} =
               Dsxir.Optimizer.GEPA.init_session(program, trainset(), metric(), [])
    end)
  end

  test "init_session returns EmptyDevset on length-1 trainset" do
    program = Dsxir.Program.new(GepaProbe)

    assert {:error, %Dsxir.Errors.Invalid.EmptyDevset{}} =
             Dsxir.Optimizer.GEPA.init_session(
               program,
               [Enum.at(trainset(), 0)],
               metric(),
               []
             )
  end

  test "serialize/deserialize round-trip on a real sampler" do
    Mimic.copy(Dsxir.Program)

    Mimic.stub(Dsxir.Program, :forward, fn prog, _ ->
      {prog, %Dsxir.Prediction{fields: %{summary: "x"}}}
    end)

    program = Dsxir.Program.new(GepaProbe)

    {:ok, sampler, _} =
      Dsxir.Optimizer.GEPA.init_session(program, trainset(), metric(),
        reflective_lm: {Dsxir.LM.Sycophant, [model: "stub"]}
      )

    {:ok, blob, 1} = Dsxir.Optimizer.GEPA.serialize_state(sampler)
    assert {:ok, restored} = Dsxir.Optimizer.GEPA.deserialize_state(blob, 1)
    assert restored.attempts == sampler.attempts
    assert restored.config == sampler.config
  end

  @tag :integration
  test "5-trial GEPA against real Sycophant terminates cleanly" do
    program = Dsxir.Program.new(GepaProbe)

    trainset =
      for i <- 1..3 do
        %Dsxir.Example{
          data: %{text: "hello #{i}", summary: "hi #{i}"},
          input_keys: MapSet.new([:text])
        }
      end

    metric = fn ex, pred, _trace ->
      summary = Map.get(pred.fields, :summary)

      %ScoreWithFeedback{
        score: if(is_binary(summary), do: 1.0, else: 0.0),
        feedback: "len=#{String.length(summary || "")} target=#{ex.data.summary}"
      }
    end

    assert {:ok, _compiled, stats} =
             Dsxir.Optimizer.GEPA.compile(program, trainset, metric,
               auto: :light,
               num_trials: 5
             )

    assert is_float(stats.best_score)
    refute Enum.any?(stats.trials, fn t -> Map.get(t, :error_class) == :framework end)
  end
end
