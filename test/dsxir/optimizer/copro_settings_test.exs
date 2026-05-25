defmodule MyApp.CoproSettingsProbe do
  @moduledoc false
  use Dsxir.Module

  predictor :answer, Dsxir.Predictor.Predict, signature: Dsxir.Test.Fixtures.AnswerQuestion
  predictor :check, Dsxir.Predictor.Predict, signature: Dsxir.Test.Fixtures.AnswerQuestion

  def forward(prog, %{question: q}) do
    {prog, _} = call(prog, :check, %{question: q})
    call(prog, :answer, %{question: q})
  end
end

defmodule Dsxir.Optimizer.COPROSettingsTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Dsxir.Example
  alias Dsxir.Optimizer.COPRO
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

  test "tenant_id from Dsxir.context propagates to predictor telemetry emitted by Evaluate workers" do
    stub_task_lm()
    parent = self()
    handler_id = "copro-settings-#{:erlang.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:dsxir, :predictor, :stop],
          [:dsxir, :optimizer, :copro, :trial]
        ],
        &TelemetryHandler.forward/4,
        %{parent: parent, tag: :tel}
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, _compiled, %Stats{}} =
      Dsxir.context(
        [lm: {Dsxir.LM.Sycophant, [model: "stub"]}, metadata: %{tenant_id: "t-42"}],
        fn ->
          Dsxir.compile(COPRO, Program.new(MyApp.CoproSettingsProbe), trainset(), &metric/3,
            auto: :light,
            proposer_lm: proposer_lm()
          )
        end
      )

    stops = drain(:tel, [:dsxir, :predictor, :stop])
    trials = drain(:tel, [:dsxir, :optimizer, :copro, :trial])

    refute stops == []
    refute trials == []

    Enum.each(stops, fn meta ->
      assert meta.tenant_id == "t-42"
    end)
  end

  defp drain(tag, event, acc \\ []) do
    receive do
      {^tag, ^event, _meas, meta} -> drain(tag, event, [meta | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
