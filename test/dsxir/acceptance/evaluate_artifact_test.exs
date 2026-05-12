defmodule Dsxir.Acceptance.EvaluateArtifactTest do
  @moduledoc """
  Acceptance regression net for the evaluate / compile / save-load surface.

  Tests 2 and 6 from the plan's six-item acceptance bar live in the
  `evaluate_test.exs` per-module suite and the integration suite respectively;
  the remaining items (1, 3, 4, 5) are exercised here.
  """

  use ExUnit.Case, async: false
  use Mimic

  alias Dsxir.Artifact
  alias Dsxir.Errors.Invalid.SignatureMismatch
  alias Dsxir.Errors.Invalid.Trainset
  alias Dsxir.Evaluate
  alias Dsxir.Optimizer.LabeledFewShot
  alias Dsxir.Program
  alias Dsxir.Test.Fixtures.QA

  defmodule Other do
    @moduledoc false
    use Dsxir.Signature

    signature do
      input(:q, :string)
      output(:different, :string)
    end
  end

  defmodule OtherProg do
    @moduledoc false
    use Dsxir.Module

    predictor(:answer, Dsxir.Predictor.Predict, signature: Other)

    def forward(p, i), do: call(p, :answer, i)
  end

  setup :set_mimic_global

  setup do
    Mimic.copy(Dsxir.LM.Sycophant)
    :ok
  end

  @tag :tmp_dir
  test "1. compile -> save -> load -> predict round-trips labeled demos through the prompt",
       %{tmp_dir: tmp_dir} do
    parent = self()

    Mimic.stub(Dsxir.LM.Sycophant, :generate_text, fn _config, messages, _opts ->
      send(parent, {:lm_messages, messages})
      {:ok, "[[ ## a ## ]]\nstubbed", Dsxir.LM.empty_usage()}
    end)

    {:ok, compiled, _stats} =
      LabeledFewShot.compile(Program.new(QA.Prog), QA.trainset_10(), &QA.exact_match/3,
        max_labeled_demos: 5,
        deterministic: true
      )

    path = Path.join(tmp_dir, "m3-compile-#{:erlang.unique_integer([:positive])}.json")
    {:ok, ^path} = Artifact.save(compiled, path)
    {:ok, restored} = Artifact.load(QA.Prog, path)

    Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      QA.Prog.forward(restored, %{q: "What is 2 + 2?"})
    end)

    assert_received {:lm_messages, messages}
    rendered = Enum.map_join(messages, "\n", & &1.content)

    Enum.each(restored.predictors[:answer].demos, fn demo ->
      assert rendered =~ demo.example.data[:q]
    end)
  end

  test "3. errors counted but do not abort run; run!/2 raises" do
    Mimic.stub(Dsxir.LM.Sycophant, :generate_text, fn _, _, _ ->
      {:ok, "no markers here", Dsxir.LM.empty_usage()}
    end)

    Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      ev = %Evaluate{
        devset: QA.devset_20(),
        metric: &QA.exact_match/3,
        num_threads: 8,
        max_errors: 100
      }

      result = Evaluate.run(ev, Program.new(QA.Prog))
      assert result.errors.count == 20

      assert_raise Dsxir.Errors.Framework.PredictorError, fn ->
        Evaluate.run!(ev, Program.new(QA.Prog))
      end
    end)
  end

  @tag :tmp_dir
  test "4. hydrate into a different module raises SignatureMismatch with non-empty diff",
       %{tmp_dir: tmp_dir} do
    {:ok, compiled, _} =
      LabeledFewShot.compile(Program.new(QA.Prog), QA.trainset_10(), &QA.exact_match/3, [])

    path = Path.join(tmp_dir, "m3-mismatch-#{:erlang.unique_integer([:positive])}.json")
    {:ok, ^path} = Artifact.save(compiled, path)

    {:error, %SignatureMismatch{diff: diff}} = Artifact.load(OtherProg, path)
    assert diff.field_diffs != %{}
  end

  test "5. empty trainset returns {:error, Invalid.Trainset{reason: :empty}}" do
    assert {:error, %Trainset{reason: :empty}} =
             LabeledFewShot.compile(Program.new(QA.Prog), [], &QA.exact_match/3, [])
  end
end
