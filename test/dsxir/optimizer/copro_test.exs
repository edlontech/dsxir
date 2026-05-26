defmodule MyApp.CoproProbe do
  @moduledoc false
  use Dsxir.Module

  predictor :answer, Dsxir.Predictor.Predict, signature: Dsxir.Test.Fixtures.AnswerQuestion
  predictor :check, Dsxir.Predictor.Predict, signature: Dsxir.Test.Fixtures.AnswerQuestion

  def forward(prog, %{question: q}) do
    {prog, _} = call(prog, :check, %{question: q})
    call(prog, :answer, %{question: q})
  end
end

defmodule MyApp.CoproNoPredictors do
  @moduledoc false
  use Dsxir.Module

  def forward(prog, _inputs), do: {prog, %Dsxir.Prediction{fields: %{}}}
end

defmodule Dsxir.Test.Fixtures.RateLimitedProposerLM do
  @moduledoc false
  @behaviour Dsxir.LM

  @impl Dsxir.LM
  def generate_text(_config, _messages, _opts) do
    {:error, %Dsxir.Errors.LM.RateLimited{model_id: "stub", retry_after: nil}}
  end

  @impl Dsxir.LM
  def generate_object(_config, _messages, _schema, _opts) do
    {:error, %Dsxir.Errors.LM.RateLimited{model_id: "stub", retry_after: nil}}
  end
end

defmodule Dsxir.Optimizer.COPROTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Dsxir.Errors
  alias Dsxir.Example
  alias Dsxir.Optimizer.COPRO
  alias Dsxir.Optimizer.COPRO.Auto
  alias Dsxir.Optimizer.COPRO.Stats
  alias Dsxir.Program
  alias Dsxir.Test.TelemetryHandler

  @winner "WINNER-INSTRUCTION"

  setup :set_mimic_global

  setup do
    prior = Dsxir.Settings.snapshot()
    on_exit(fn -> :persistent_term.put({Dsxir.Settings, :globals}, prior.globals) end)
    :ok
  end

  defp ex(q, a), do: Example.new(%{question: q, answer: a}, input_keys: [:question])

  defp trainset, do: Enum.map(1..4, fn i -> ex("q-#{i}", "a-#{i}") end)

  # Rewards the :answer predictor's output only when the winning instruction is
  # present in its system prompt (which the task LM echoes into the answer).
  defp metric(_ex, %Dsxir.Prediction{fields: %{answer: a}}, _t) when is_binary(a) do
    if String.contains?(a, "won"), do: 1.0, else: 0.0
  end

  defp proposer_lm do
    reply = """
    1. #{@winner}
    2. distractor-A
    3. distractor-B
    4. distractor-C
    """

    {Dsxir.Test.Fixtures.StubProposerLM, [model: "stub", reply: reply]}
  end

  # Task LM: scans the system prompt for the winner token and answers "won"
  # when present, "lost" otherwise, so the metric is a pure function of the
  # instruction override applied to the predictor.
  defp stub_task_lm do
    Mimic.stub(Dsxir.LM.Sycophant, :generate_text, fn _config, messages, _opts ->
      system =
        messages
        |> Enum.filter(fn m -> m.role == :system end)
        |> Enum.map_join("\n", & &1.content)

      verdict = if String.contains?(system, @winner), do: "won", else: "lost"
      {:ok, "[[ ## answer ## ]]\n#{verdict}", Dsxir.LM.empty_usage()}
    end)
  end

  describe "input validation" do
    test "empty trainset returns {:error, Invalid.Trainset{reason: :empty}}" do
      assert {:error, %Errors.Invalid.Trainset{reason: :empty}} =
               COPRO.compile(Program.new(MyApp.CoproProbe), [], &metric/3, [])
    end

    test "zero predictors returns {:error, Invalid.Trainset{reason: :no_predictors}}" do
      assert {:error, %Errors.Invalid.Trainset{reason: :no_predictors}} =
               COPRO.compile(Program.new(MyApp.CoproNoPredictors), trainset(), &metric/3,
                 auto: :light
               )
    end
  end

  describe "end-to-end compile" do
    test "coordinate ascent commits the rewarded instruction over two rounds" do
      stub_task_lm()
      proposer = proposer_lm()

      base_score =
        Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
          {:ok, score, _} =
            Dsxir.Optimizer.COPRO.Evaluator.run(
              Program.new(MyApp.CoproProbe),
              trainset(),
              &metric/3,
              %{}
            )

          score
        end)

      assert base_score == 0.0

      {:ok, compiled, %Stats{} = stats} =
        Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
          Dsxir.compile(COPRO, Program.new(MyApp.CoproProbe), trainset(), &metric/3,
            auto: :light,
            proposer_lm: proposer
          )
        end)

      assert stats.rounds == 2
      assert stats.best_score >= base_score
      assert stats.best_score > 0.0
      assert compiled.metadata.compiled_with == COPRO
      assert %{answer: best_answer_instr} = stats.best_instructions
      assert best_answer_instr == @winner

      state = Program.get_state(compiled, :answer)
      assert state.instructions_override == @winner
    end

    test "compile! returns {program, stats} and raises on invalid trainset" do
      stub_task_lm()

      {compiled, %Stats{}} =
        Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
          COPRO.compile!(Program.new(MyApp.CoproProbe), trainset(), &metric/3,
            auto: :light,
            proposer_lm: proposer_lm()
          )
        end)

      assert %Program{} = compiled

      assert_raise Errors.Invalid.Trainset, fn ->
        COPRO.compile!(Program.new(MyApp.CoproProbe), [], &metric/3, [])
      end
    end
  end

  describe "checkpointing" do
    test "serialize_state/deserialize_state round-trips the session sampler" do
      stub_task_lm()

      {:ok, sampler, total} =
        Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
          COPRO.init_session(Program.new(MyApp.CoproProbe), trainset(), &metric/3,
            auto: :light,
            proposer_lm: proposer_lm()
          )
        end)

      light = Auto.preset(:light)
      # planned trials == depth * predictors * breadth (CoproProbe has 2 predictors)
      assert total == light.depth * 2 * light.breadth
      assert {:ok, blob, version} = COPRO.serialize_state(sampler)
      assert {:ok, restored} = COPRO.deserialize_state(blob, version)
      assert restored.queue == sampler.queue
      assert restored.best_overrides == sampler.best_overrides
    end

    test "the optimizer is reported as checkpointable" do
      assert {:ok, COPRO} = Dsxir.Optimizer.checkpointable?(COPRO)
    end
  end

  describe "telemetry" do
    test "emits one start/stop and one trial per evaluated candidate" do
      stub_task_lm()
      parent = self()
      handler_id = "copro-telemetry-#{:erlang.unique_integer([:positive])}"

      :ok =
        :telemetry.attach_many(
          handler_id,
          [
            [:dsxir, :optimizer, :start],
            [:dsxir, :optimizer, :stop],
            [:dsxir, :optimizer, :copro, :trial],
            [:dsxir, :optimizer, :copro, :round]
          ],
          &TelemetryHandler.forward/4,
          %{parent: parent, tag: :tel}
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      {:ok, _compiled, %Stats{} = stats} =
        Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
          Dsxir.compile(COPRO, Program.new(MyApp.CoproProbe), trainset(), &metric/3,
            auto: :light,
            proposer_lm: proposer_lm()
          )
        end)

      starts = drain(:tel, [:dsxir, :optimizer, :start])
      stops = drain(:tel, [:dsxir, :optimizer, :stop])
      trials = drain(:tel, [:dsxir, :optimizer, :copro, :trial])
      rounds = drain(:tel, [:dsxir, :optimizer, :copro, :round])

      assert starts == 1
      assert stops == 1
      light = Auto.preset(:light)
      # one trial per candidate == depth * predictors * breadth (CoproProbe has 2 predictors)
      assert trials == length(stats.trials)
      assert trials == light.depth * 2 * light.breadth
      assert rounds == light.depth
    end
  end

  describe "degraded proposer path" do
    test "all-proposer-fail keeps base instructions and marks stats degraded" do
      stub_task_lm()
      rate_limited = {Dsxir.Test.Fixtures.RateLimitedProposerLM, [model: "stub"]}

      base_overrides =
        Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
          {:ok, sampler, _total} =
            COPRO.init_session(Program.new(MyApp.CoproProbe), trainset(), &metric/3,
              auto: :light,
              proposer_lm: rate_limited
            )

          sampler.best_overrides
        end)

      {:ok, _compiled, %Stats{} = stats} =
        Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
          Dsxir.compile(COPRO, Program.new(MyApp.CoproProbe), trainset(), &metric/3,
            auto: :light,
            proposer_lm: rate_limited
          )
        end)

      light = Auto.preset(:light)
      assert stats.degraded == true
      assert stats.best_instructions == base_overrides
      assert stats.rounds == light.depth
    end

    test "proposer short completion is padded to breadth and runs depth rounds" do
      stub_task_lm()
      short = {Dsxir.Test.Fixtures.StubProposerLM, [model: "stub", reply: "1. #{@winner}"]}

      {:ok, _compiled, %Stats{} = stats} =
        Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
          Dsxir.compile(COPRO, Program.new(MyApp.CoproProbe), trainset(), &metric/3,
            auto: :light,
            proposer_lm: short
          )
        end)

      light = Auto.preset(:light)
      assert stats.rounds == light.depth
      assert length(stats.trials) == light.depth * 2 * light.breadth
    end
  end

  describe "real LM" do
    @tag :integration
    @tag timeout: 300_000
    test "auto: :light COPRO terminates cleanly against Sycophant" do
      trainset = [
        ex("What is 2+2?", "4"),
        ex("What is the capital of France?", "Paris"),
        ex("What color is the sky?", "blue")
      ]

      metric = fn _ex, %Dsxir.Prediction{fields: fields}, _t ->
        if is_binary(Map.get(fields, :answer)), do: 1.0, else: 0.0
      end

      lm = {Dsxir.LM.Sycophant, [model: "openai:gpt-4o-mini"]}

      result =
        Dsxir.context([lm: lm], fn ->
          Dsxir.compile(COPRO, Program.new(MyApp.CoproProbe), trainset, metric,
            auto: :light,
            proposer_lm: lm
          )
        end)

      assert {:ok, %Program{}, %Stats{} = stats} = result
      assert is_float(stats.best_score)
      assert stats.rounds == Auto.preset(:light).depth
      refute stats.trials == []
    end
  end

  defp drain(tag, event, acc \\ 0) do
    receive do
      {^tag, ^event, _, _} -> drain(tag, event, acc + 1)
    after
      0 -> acc
    end
  end
end
