defmodule Dsxir.Acceptance.BootstrapFewShotTest do
  @moduledoc """
  Mimic-backed acceptance regression net for the BootstrapFewShot surface.

  Covers acceptance items 1, 3, and 5 from the BootstrapFewShot acceptance
  criteria. Item 2 (live lift) lives in the integration suite and item 6
  (full validation pass) is the final-validation gate. Item 4 (cross-module
  hydrate) is exercised by the existing evaluate/artifact acceptance suite
  and is re-run as part of the gate, not duplicated here.
  """

  use ExUnit.Case, async: false
  use Mimic

  alias Dsxir.Artifact
  alias Dsxir.Optimizer.BootstrapFewShot
  alias Dsxir.Program
  alias Dsxir.Test.Fixtures.QA

  setup :set_mimic_global

  setup do
    Mimic.copy(Dsxir.LM.Sycophant)
    :ok
  end

  defp good_metric(_e, %Dsxir.Prediction{fields: %{a: a}}, _t) when is_binary(a) do
    if String.starts_with?(a, "good-"), do: 1.0, else: 0.0
  end

  defp good_metric(_, _, _), do: 0.0

  @tag :tmp_dir
  test "compile -> bootstrapped demos -> save -> load preserves kind tag",
       %{tmp_dir: tmp_dir} do
    Mimic.stub(Dsxir.LM.Sycophant, :generate_text, fn _config, _messages, _opts ->
      {:ok, "[[ ## a ## ]]\ngood-answer", Dsxir.LM.empty_usage()}
    end)

    Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      {:ok, compiled, _stats} =
        BootstrapFewShot.compile(
          Program.new(QA.Prog),
          QA.trainset_10(),
          &good_metric/3,
          max_labeled_demos: 2,
          max_bootstrapped_demos: 3,
          max_rounds: 1,
          threshold: 1.0,
          deterministic: true
        )

      path = Path.join(tmp_dir, "bootstrap-#{:erlang.unique_integer([:positive])}.json")
      {:ok, ^path} = Artifact.save(compiled, path)
      {:ok, restored} = Artifact.load(QA.Prog, path)

      demos = restored.predictors[:answer].demos
      kinds = demos |> Enum.map(& &1.kind) |> Enum.uniq() |> Enum.sort()

      assert :labeled in kinds
      assert :bootstrapped in kinds
    end)
  end

  @tag :tmp_dir
  test "compile -> save -> load -> forward: bootstrapped demos appear in the prompt",
       %{tmp_dir: tmp_dir} do
    parent = self()

    Mimic.stub(Dsxir.LM.Sycophant, :generate_text, fn _config, messages, _opts ->
      send(parent, {:lm_messages, messages})
      {:ok, "[[ ## a ## ]]\ngood-answer", Dsxir.LM.empty_usage()}
    end)

    Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      {:ok, compiled, _stats} =
        BootstrapFewShot.compile(
          Program.new(QA.Prog),
          QA.trainset_10(),
          &good_metric/3,
          max_labeled_demos: 0,
          max_bootstrapped_demos: 2,
          max_rounds: 1,
          threshold: 1.0,
          deterministic: true
        )

      path = Path.join(tmp_dir, "bootstrap-#{:erlang.unique_integer([:positive])}.json")
      {:ok, ^path} = Artifact.save(compiled, path)
      {:ok, restored} = Artifact.load(QA.Prog, path)

      bootstrapped =
        restored.predictors[:answer].demos
        |> Enum.filter(&match?(%Dsxir.Demo{kind: :bootstrapped}, &1))

      assert bootstrapped != []

      flush_lm_messages()

      QA.Prog.forward(restored, %{q: "What is 2 + 2?"})

      assert_received {:lm_messages, messages}
      rendered = Enum.map_join(messages, "\n", & &1.content)

      Enum.each(bootstrapped, fn demo ->
        assert rendered =~ demo.example.data[:q]
      end)
    end)
  end

  test "trace slot stays nil outside with_trace" do
    Mimic.stub(Dsxir.LM.Sycophant, :generate_text, fn _config, _messages, _opts ->
      {:ok, "[[ ## a ## ]]\nstubbed", Dsxir.LM.empty_usage()}
    end)

    refute Dsxir.Trace.active?()

    Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      QA.Prog.forward(Program.new(QA.Prog), %{q: "What is 2 + 2?"})
    end)

    refute Dsxir.Trace.active?()
    assert Process.get({Dsxir.Trace, :collector}) == nil
  end

  defp flush_lm_messages do
    receive do
      {:lm_messages, _} -> flush_lm_messages()
    after
      0 -> :ok
    end
  end
end
