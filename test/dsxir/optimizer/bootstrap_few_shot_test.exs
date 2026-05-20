defmodule Dsxir.Optimizer.BootstrapFewShotTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Dsxir.Optimizer.BootstrapFewShot
  alias Dsxir.Program
  alias Dsxir.Test.Fixtures.QA

  setup :set_mimic_global

  setup do
    Mimic.copy(Dsxir.LM.Sycophant)
    :ok
  end

  defp scripted_lm(answer_for_idx) do
    counter = :counters.new(1, [:atomics])

    Mimic.stub(Dsxir.LM.Sycophant, :generate_text, fn _config, _messages, _opts ->
      :counters.add(counter, 1, 1)
      idx = :counters.get(counter, 1)
      answer = answer_for_idx.(idx)
      {:ok, "[[ ## a ## ]]\n#{answer}", Dsxir.LM.empty_usage()}
    end)
  end

  defp threshold_metric(_e, %Dsxir.Prediction{fields: %{a: a}}, _t) when is_binary(a) do
    if String.starts_with?(a, "good-"), do: 1.0, else: 0.0
  end

  test "empty trainset returns {:error, Invalid.Trainset{reason: :empty}}" do
    assert {:error, %Dsxir.Errors.Invalid.Trainset{reason: :empty, example: nil}} =
             BootstrapFewShot.compile(Program.new(QA.Prog), [], &threshold_metric/3, [])
  end

  test "phase 1 slots labeled demos with kind :labeled" do
    scripted_lm(fn _ -> "good-stubbed" end)

    Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      trainset = QA.trainset_10()

      {:ok, compiled, stats} =
        BootstrapFewShot.compile(Program.new(QA.Prog), trainset, &threshold_metric/3,
          max_labeled_demos: 3,
          max_bootstrapped_demos: 0,
          max_rounds: 1,
          deterministic: true
        )

      assert stats.labeled_demos == 3
      assert stats.bootstrapped_demos == 0

      demos = Program.get_state(compiled, :answer).demos
      assert length(demos) == 3
      assert Enum.all?(demos, &match?(%Dsxir.Demo{kind: :labeled}, &1))
    end)
  end

  test "phase 2 captures bootstrapped demos with source tagging" do
    scripted_lm(fn idx -> if rem(idx, 2) == 0, do: "good-#{idx}", else: "bad-#{idx}" end)

    Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      trainset = QA.trainset_10()

      {:ok, compiled, stats} =
        BootstrapFewShot.compile(Program.new(QA.Prog), trainset, &threshold_metric/3,
          max_labeled_demos: 0,
          max_bootstrapped_demos: 3,
          max_rounds: 1,
          threshold: 1.0,
          deterministic: true
        )

      assert stats.labeled_demos == 0
      assert stats.bootstrapped_demos == 3

      demos = Program.get_state(compiled, :answer).demos
      assert length(demos) == 3
      assert Enum.all?(demos, &match?(%Dsxir.Demo{kind: :bootstrapped}, &1))
      assert Enum.all?(demos, fn d -> match?(%{round: 1, example_index: _}, d.source) end)
    end)
  end

  test "phase 2 forwards diversity temperature to the LM" do
    parent = self()

    Mimic.stub(Dsxir.LM.Sycophant, :generate_text, fn config, _messages, opts ->
      send(parent, {:lm_call, config, opts})
      {:ok, "[[ ## a ## ]]\ngood-x", Dsxir.LM.empty_usage()}
    end)

    Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      {:ok, _compiled, _stats} =
        BootstrapFewShot.compile(
          Program.new(QA.Prog),
          QA.trainset_10() |> Enum.take(1),
          &threshold_metric/3,
          max_labeled_demos: 0,
          max_bootstrapped_demos: 1,
          max_rounds: 1,
          diversity_temperature: 1.0,
          deterministic: true
        )
    end)

    assert_received {:lm_call, config, _opts}
    assert config[:temperature] == 1.0
    assert config[:cache] == false
    assert match?({_, _, _}, config[:_dsxir_nonce])
  end

  defmodule HeadSig do
    use Dsxir.Signature

    signature do
      input(:q, :string)
      output(:topic, :string)
    end
  end

  defmodule TailSig do
    use Dsxir.Signature

    signature do
      input(:topic, :string)
      output(:answer, :string)
    end
  end

  defmodule TwoStepProg do
    use Dsxir.Module

    predictor(:head, Dsxir.Predictor.ChainOfThought, signature: HeadSig)
    predictor(:tail, Dsxir.Predictor.Predict, signature: TailSig)

    def forward(p, %{q: q}) do
      {p, head} = call(p, :head, %{q: q})
      {p, tail} = call(p, :tail, %{topic: head.fields.topic})
      {p, tail}
    end
  end

  defp pair_metric(_e, %Dsxir.Prediction{fields: %{answer: a}}, _t) when is_binary(a) do
    if String.starts_with?(a, "good-"), do: 1.0, else: 0.0
  end

  @tag :tmp_dir
  test "multi-predictor pipeline with ChainOfThought saves and loads cleanly",
       %{tmp_dir: tmp_dir} do
    counter = :counters.new(1, [:atomics])

    Mimic.stub(Dsxir.LM.Sycophant, :generate_text, fn _config, _messages, _opts ->
      :counters.add(counter, 1, 1)
      idx = :counters.get(counter, 1)

      payload =
        case rem(idx, 2) do
          1 ->
            "[[ ## reasoning ## ]]\nbecause #{idx}\n\n[[ ## topic ## ]]\ntopic-#{idx}"

          0 ->
            "[[ ## answer ## ]]\ngood-#{idx}"
        end

      {:ok, payload, Dsxir.LM.empty_usage()}
    end)

    trainset =
      Enum.map(1..3, fn i ->
        Dsxir.Example.new(%{q: "q#{i}", answer: "good-#{i}"}, input_keys: [:q])
      end)

    Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      {:ok, compiled, stats} =
        BootstrapFewShot.compile(
          Program.new(TwoStepProg),
          trainset,
          &pair_metric/3,
          max_labeled_demos: 2,
          max_bootstrapped_demos: 2,
          max_rounds: 1,
          threshold: 1.0,
          deterministic: true
        )

      assert stats.predictor_count == 2

      head_demos = Program.get_state(compiled, :head).demos
      tail_demos = Program.get_state(compiled, :tail).demos

      assert Enum.all?(head_demos, &match?(%Dsxir.Demo{}, &1))
      assert Enum.all?(tail_demos, &match?(%Dsxir.Demo{}, &1))

      path = Path.join(tmp_dir, "two-step-#{:erlang.unique_integer([:positive])}.json")
      assert {:ok, ^path} = Dsxir.Artifact.save(compiled, path)
      assert {:ok, _reloaded} = Dsxir.Artifact.load(TwoStepProg, path)
    end)
  end

  test "labeled demos do not land in predictors they cannot fill" do
    Mimic.stub(Dsxir.LM.Sycophant, :generate_text, fn _, _, _ ->
      {:ok, "[[ ## answer ## ]]\ngood-stub", Dsxir.LM.empty_usage()}
    end)

    trainset =
      Enum.map(1..3, fn i ->
        Dsxir.Example.new(%{q: "q#{i}", answer: "good-#{i}"}, input_keys: [:q])
      end)

    Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      {:ok, compiled, _stats} =
        BootstrapFewShot.compile(
          Program.new(TwoStepProg),
          trainset,
          &pair_metric/3,
          max_labeled_demos: 3,
          max_bootstrapped_demos: 0,
          max_rounds: 1,
          threshold: 1.0,
          deterministic: true
        )

      head_demos = Program.get_state(compiled, :head).demos
      tail_demos = Program.get_state(compiled, :tail).demos

      assert head_demos == []
      assert tail_demos == []
    end)
  end

  test "metadata.compiled_with and trainset_hash are stamped" do
    scripted_lm(fn _ -> "good-stub" end)

    Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      {:ok, compiled, _} =
        BootstrapFewShot.compile(Program.new(QA.Prog), QA.trainset_10(), &threshold_metric/3,
          max_labeled_demos: 1,
          max_bootstrapped_demos: 1,
          max_rounds: 1
        )

      assert compiled.metadata.compiled_with == BootstrapFewShot
      assert compiled.metadata.score == nil
      assert is_binary(compiled.metadata.trainset_hash)
      assert byte_size(compiled.metadata.trainset_hash) == 64
    end)
  end

  test "errors aggregate and exceed max_errors yields Framework.OptimizerError" do
    Mimic.stub(Dsxir.LM.Sycophant, :generate_text, fn _, _, _ ->
      {:error,
       %Dsxir.Errors.LM.RequestFailed{
         model_id: "stub",
         status: 500,
         parent_error: :boom
       }}
    end)

    Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      assert {:error,
              %Dsxir.Errors.Framework.OptimizerError{
                optimizer: BootstrapFewShot,
                inner: inner
              }} =
               BootstrapFewShot.compile(
                 Program.new(QA.Prog),
                 QA.trainset_10(),
                 &threshold_metric/3,
                 max_labeled_demos: 0,
                 max_bootstrapped_demos: 1,
                 max_rounds: 1,
                 max_errors: 2,
                 deterministic: true
               )

      refute is_nil(inner)
    end)
  end

  defmodule DegradedProg do
    use Dsxir.Module

    predictor(:answer, Dsxir.Predictor.Predict, signature: Dsxir.Test.Fixtures.QA.Sig)

    def forward(p, inputs) do
      Dsxir.Module.Runtime.call(p, :answer, inputs, degraded: true)
    end
  end

  test "degraded_demos: :exclude (default) drops degraded entries from the pool" do
    scripted_lm(fn _ -> "good-stub" end)

    Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      {:ok, compiled, stats} =
        BootstrapFewShot.compile(
          Program.new(DegradedProg),
          QA.trainset_10(),
          &threshold_metric/3,
          max_labeled_demos: 0,
          max_bootstrapped_demos: 3,
          max_rounds: 1,
          threshold: 1.0,
          deterministic: true
        )

      assert stats.bootstrapped_demos == 0
      assert Program.get_state(compiled, :answer).demos == []
    end)
  end

  test "degraded_demos: :include keeps degraded entries in the pool" do
    scripted_lm(fn idx -> "good-#{idx}" end)

    Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      {:ok, compiled, stats} =
        BootstrapFewShot.compile(
          Program.new(DegradedProg),
          QA.trainset_10(),
          &threshold_metric/3,
          max_labeled_demos: 0,
          max_bootstrapped_demos: 3,
          max_rounds: 1,
          threshold: 1.0,
          deterministic: true,
          degraded_demos: :include
        )

      assert stats.bootstrapped_demos == 3
      demos = Program.get_state(compiled, :answer).demos
      assert length(demos) == 3
      assert Enum.all?(demos, &match?(%Dsxir.Demo{kind: :bootstrapped}, &1))
    end)
  end

  test "degraded_demos: <invalid> raises FunctionClauseError during option parsing" do
    scripted_lm(fn _ -> "good-stub" end)

    Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      assert_raise FunctionClauseError, fn ->
        BootstrapFewShot.compile(
          Program.new(QA.Prog),
          QA.trainset_10(),
          &threshold_metric/3,
          max_labeled_demos: 0,
          max_bootstrapped_demos: 1,
          max_rounds: 1,
          degraded_demos: :nonsense
        )
      end
    end)
  end

  test "telemetry: emits start, trial, and stop" do
    scripted_lm(fn _ -> "good-stub" end)
    parent = self()

    handler_id = "bootstrap-few-shot-#{:erlang.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      [
        [:dsxir, :optimizer, :start],
        [:dsxir, :optimizer, :stop],
        [:dsxir, :optimizer, :trial]
      ],
      &Dsxir.Test.TelemetryHandler.forward/4,
      %{parent: parent, tag: :bootstrap_telemetry}
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      _ =
        BootstrapFewShot.compile(Program.new(QA.Prog), QA.trainset_10(), &threshold_metric/3,
          max_labeled_demos: 0,
          max_bootstrapped_demos: 2,
          max_rounds: 1,
          threshold: 1.0,
          deterministic: true
        )
    end)

    assert_received {:bootstrap_telemetry, [:dsxir, :optimizer, :start], _,
                     %{optimizer: BootstrapFewShot, error_class: nil}}

    assert_received {:bootstrap_telemetry, [:dsxir, :optimizer, :trial], _,
                     %{round: 1, error_class: nil}}

    assert_received {:bootstrap_telemetry, [:dsxir, :optimizer, :stop], _,
                     %{optimizer: BootstrapFewShot, error_class: nil}}
  end
end
