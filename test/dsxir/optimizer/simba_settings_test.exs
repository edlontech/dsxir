defmodule Dsxir.Optimizer.SIMBASettingsTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Dsxir.Optimizer.SIMBA
  alias Dsxir.Optimizer.SIMBA.Stats
  alias Dsxir.Program
  alias Dsxir.Test.Fixtures.QA
  alias Dsxir.Test.TelemetryHandler

  setup :set_mimic_global

  setup do
    prior = Dsxir.Settings.snapshot()
    on_exit(fn -> :persistent_term.put({Dsxir.Settings, :globals}, prior.globals) end)
    :ok
  end

  @opts [auto: :light, bsize: 3, max_steps: 2, num_candidates: 2, seed: 1, num_threads: 2]

  defp trainset do
    for i <- 0..5, do: Dsxir.Example.new(%{q: "q#{i}", a: "good"}, input_keys: [:q])
  end

  defp metric(_ex, %Dsxir.Prediction{fields: %{a: a}}, _trace) when is_binary(a) do
    if a == "good", do: 1.0, else: 0.0
  end

  defp metric(_ex, _pred, _trace), do: 0.0

  defp stub_task_lm do
    Mimic.stub(Dsxir.LM.Sycophant, :generate_text, fn _config, _messages, _opts ->
      {:ok, "[[ ## a ## ]]\ngood", Dsxir.LM.empty_usage()}
    end)
  end

  test "tenant_id from Dsxir.context rides every predictor event emitted by SIMBA evaluator workers" do
    stub_task_lm()
    parent = self()
    handler_id = "simba-settings-#{:erlang.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:dsxir, :predictor, :stop],
          [:dsxir, :optimizer, :simba, :trial]
        ],
        &TelemetryHandler.forward/4,
        %{parent: parent, tag: :tel}
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, _compiled, %Stats{}} =
      Dsxir.context(
        [lm: {Dsxir.LM.Sycophant, [model: "stub"]}, metadata: %{tenant_id: "t-42"}],
        fn ->
          Dsxir.compile(SIMBA, Program.new(QA.Prog), trainset(), &metric/3, @opts)
        end
      )

    stops = drain(:tel, [:dsxir, :predictor, :stop])
    trials = drain(:tel, [:dsxir, :optimizer, :simba, :trial])

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
