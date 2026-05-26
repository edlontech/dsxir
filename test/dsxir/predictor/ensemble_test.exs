defmodule Dsxir.Predictor.EnsembleTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Dsxir.Prediction
  alias Dsxir.Predictor.Ensemble
  alias Dsxir.Program

  setup :set_mimic_global

  setup do
    Mimic.copy(Program)
    :ok
  end

  defp pred(fields), do: %Prediction{fields: fields}

  defp prog(tag), do: %Program{source: %Program.Source.Module{module: tag}, predictors: %{}}

  defp stub_answers(mapping) do
    stub(Program, :forward, fn %Program{source: %Program.Source.Module{module: m}}, _i, _o ->
      case Map.fetch!(mapping, m) do
        {:raise, msg} -> raise RuntimeError, msg
        answer -> {prog(m), %Prediction{fields: %{answer: answer}}}
      end
    end)
  end

  describe "majority/2" do
    test "votes on the full fields map by default" do
      preds = [pred(%{answer: "yes"}), pred(%{answer: "no"}), pred(%{answer: "yes"})]
      assert %Prediction{fields: %{answer: "yes"}} = Ensemble.majority(preds)
    end

    test "votes on a single field when :field is given" do
      preds = [
        pred(%{answer: "yes", note: "a"}),
        pred(%{answer: "yes", note: "b"}),
        pred(%{answer: "no", note: "c"})
      ]

      assert %Prediction{fields: %{answer: "yes", note: "a"}} =
               Ensemble.majority(preds, field: :answer)
    end

    test "breaks ties by first occurrence" do
      preds = [pred(%{answer: "b"}), pred(%{answer: "a"})]
      assert %Prediction{fields: %{answer: "b"}} = Ensemble.majority(preds)
    end

    test "returns a real member prediction preserving its other data" do
      preds = [pred(%{answer: "x", n: 1}), pred(%{answer: "x", n: 2})]
      assert %Prediction{fields: %{answer: "x", n: 1}} = Ensemble.majority(preds, field: :answer)
    end
  end

  describe "run/3" do
    test "runs all members and returns the raw list when no reduce_fn" do
      stub_answers(%{ProgA: "yes", ProgB: "no", ProgC: "yes"})

      result = Ensemble.run([prog(:ProgA), prog(:ProgB), prog(:ProgC)], %{q: "?"})

      assert [
               %Prediction{fields: %{answer: "yes"}},
               %Prediction{fields: %{answer: "no"}},
               %Prediction{fields: %{answer: "yes"}}
             ] =
               result
    end

    test "reduces with the supplied reduce_fn" do
      stub_answers(%{ProgA: "yes", ProgB: "no", ProgC: "yes"})

      result =
        Ensemble.run([prog(:ProgA), prog(:ProgB), prog(:ProgC)], %{q: "?"},
          reduce_fn: &Ensemble.majority/1
        )

      assert %Prediction{fields: %{answer: "yes"}} = result
    end

    test "subsamples to :size programs" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      stub(Program, :forward, fn p, _i, _o ->
        Agent.update(counter, &(&1 + 1))
        {p, %Prediction{fields: %{answer: "a"}}}
      end)

      Ensemble.run([prog(:ProgA), prog(:ProgB), prog(:ProgC)], %{q: "?"}, size: 2)

      assert Agent.get(counter, & &1) == 2
    end

    @tag :capture_log
    test "tolerates a failing member and reduces over survivors" do
      stub_answers(%{ProgA: "yes", ProgB: {:raise, "boom"}, ProgC: "yes"})

      result =
        Ensemble.run([prog(:ProgA), prog(:ProgB), prog(:ProgC)], %{q: "?"},
          reduce_fn: &Ensemble.majority/1
        )

      assert %Prediction{fields: %{answer: "yes"}} = result
    end

    @tag :capture_log
    test "raises all_failed when every member fails" do
      stub_answers(%{ProgA: {:raise, "a"}, ProgB: {:raise, "b"}})

      assert_raise Dsxir.Errors.Framework.PredictorError, fn ->
        Ensemble.run([prog(:ProgA), prog(:ProgB)], %{q: "?"})
      end
    end

    test "raises ArgumentError on empty program list" do
      assert_raise ArgumentError, fn -> Ensemble.run([], %{q: "?"}) end
    end

    test "raises ArgumentError on non-map inputs with a valid program list" do
      assert_raise ArgumentError, fn -> Ensemble.run([prog(:ProgA)], nil) end
    end

    test "raises ArgumentError on a non-positive :size" do
      stub_answers(%{ProgA: "a"})

      assert_raise ArgumentError, fn ->
        Ensemble.run([prog(:ProgA)], %{q: "?"}, size: 0)
      end
    end

    @tag :capture_log
    test "tolerates a timed-out member and reduces over survivors" do
      stub(Program, :forward, fn %Program{source: %Program.Source.Module{module: m}}, _i, _o ->
        if m == :Slow, do: Process.sleep(200)
        {prog(m), %Prediction{fields: %{answer: "yes"}}}
      end)

      result =
        Ensemble.run([prog(:ProgA), prog(:Slow)], %{q: "?"},
          timeout: 50,
          reduce_fn: &Ensemble.majority/1
        )

      assert %Prediction{fields: %{answer: "yes"}} = result
    end
  end

  describe "telemetry" do
    test "emits one :member event per program and one :stop, carrying tenant metadata" do
      stub(Program, :forward, fn p, _i, _o -> {p, %Prediction{fields: %{answer: "a"}}} end)

      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:dsxir, :predictor, :ensemble, :member],
          [:dsxir, :predictor, :ensemble, :stop]
        ])

      on_exit(fn -> :telemetry.detach(ref) end)

      Dsxir.Settings.context([metadata: %{tenant_id: "t-7"}], fn ->
        Ensemble.run([prog(:ProgA), prog(:ProgB)], %{q: "?"}, reduce_fn: &Ensemble.majority/1)
      end)

      assert_received {[:dsxir, :predictor, :ensemble, :member], ^ref, _,
                       %{tenant_id: "t-7", ok?: true}}

      assert_received {[:dsxir, :predictor, :ensemble, :member], ^ref, _, %{tenant_id: "t-7"}}

      assert_received {[:dsxir, :predictor, :ensemble, :stop], ^ref,
                       %{members_run: 2, successes: 2}, %{tenant_id: "t-7", reduced?: true}}
    end
  end
end
