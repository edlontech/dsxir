defmodule Dsxir.EvaluateTest do
  use ExUnit.Case, async: false

  use Mimic

  alias Dsxir.Evaluate
  alias Dsxir.EvaluationResult
  alias Dsxir.Test.TelemetryHandler

  setup :set_mimic_global

  setup do
    Mimic.copy(Dsxir.LM.Sycophant)
    prior = Dsxir.Settings.snapshot()
    on_exit(fn -> :persistent_term.put({Dsxir.Settings, :globals}, prior.globals) end)
    :ok
  end

  defmodule Sig do
    use Dsxir.Signature

    signature do
      input(:q, :string)
      output(:a, :string)
    end
  end

  defmodule Prog do
    use Dsxir.Module

    predictor(:answer, Dsxir.Predictor.Predict, signature: Sig)

    def forward(p, inputs), do: call(p, :answer, inputs)
  end

  defp ex(q, a), do: Dsxir.Example.new(%{q: q, a: a}, input_keys: [:q])

  defp metric(_e, %Dsxir.Prediction{fields: %{a: actual}}, _t) do
    if actual == "ok", do: 1.0, else: 0.0
  end

  test "score is avg(metric) * 100, rounded to 1dp" do
    Mimic.stub(Dsxir.LM.Sycophant, :generate_text, fn _c, _msgs, _opts ->
      {:ok, "[[ ## a ## ]]\nok", Dsxir.LM.empty_usage()}
    end)

    Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      ev = %Evaluate{
        devset: Enum.map(1..4, &ex("q#{&1}", "ok")),
        metric: &metric/3,
        num_threads: 2
      }

      result = Evaluate.run(ev, Dsxir.Program.new(Prog))
      assert result.score == 100.0
      assert length(result.results) == 4
      assert result.errors.count == 0
    end)
  end

  test "errors are counted by class and do not abort the run" do
    Mimic.stub(Dsxir.LM.Sycophant, :generate_text, fn _c, _msgs, _opts ->
      {:ok, "no markers", Dsxir.LM.empty_usage()}
    end)

    Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      ev = %Evaluate{
        devset: Enum.map(1..3, &ex("q#{&1}", "ok")),
        metric: &metric/3,
        num_threads: 2,
        failure_score: 0.0
      }

      result = Evaluate.run(ev, Dsxir.Program.new(Prog))
      assert result.errors.count == 3
      assert map_size(result.errors.by_class) >= 1
      assert Enum.sum(Map.values(result.errors.by_class)) == 3
      assert result.score == 0.0
    end)
  end

  test "run!/2 raises on any per-example error" do
    Mimic.stub(Dsxir.LM.Sycophant, :generate_text, fn _c, _msgs, _opts ->
      {:ok, "no markers", Dsxir.LM.empty_usage()}
    end)

    Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      ev = %Evaluate{
        devset: [ex("q1", "ok")],
        metric: &metric/3,
        num_threads: 1
      }

      assert_raise Dsxir.Errors.Framework.PredictorError, fn ->
        Evaluate.run!(ev, Dsxir.Program.new(Prog))
      end
    end)
  end

  test "run!/2 returns the result when no errors occurred" do
    Mimic.stub(Dsxir.LM.Sycophant, :generate_text, fn _c, _msgs, _opts ->
      {:ok, "[[ ## a ## ]]\nok", Dsxir.LM.empty_usage()}
    end)

    Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      ev = %Evaluate{devset: [ex("q1", "ok")], metric: &metric/3}
      result = Evaluate.run!(ev, Dsxir.Program.new(Prog))
      assert %EvaluationResult{errors: %{count: 0}} = result
    end)
  end

  test "[:dsxir, :evaluate, :item] and :stop emit with expected meas/meta" do
    Mimic.stub(Dsxir.LM.Sycophant, :generate_text, fn _c, _msgs, _opts ->
      {:ok, "[[ ## a ## ]]\nok", Dsxir.LM.empty_usage()}
    end)

    parent = self()
    ref = make_ref()
    handler_id = {__MODULE__, ref}

    :telemetry.attach_many(
      handler_id,
      [[:dsxir, :evaluate, :item], [:dsxir, :evaluate, :stop]],
      &TelemetryHandler.forward/4,
      %{parent: parent, tag: ref}
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      ev = %Evaluate{devset: [ex("q1", "ok"), ex("q2", "ok")], metric: &metric/3, num_threads: 2}
      _ = Evaluate.run(ev, Dsxir.Program.new(Prog))
    end)

    assert_receive {^ref, [:dsxir, :evaluate, :item], %{duration: _, metric_value: 1.0},
                    %{example: _, prediction: %Dsxir.Prediction{}, error_class: nil}}

    assert_receive {^ref, [:dsxir, :evaluate, :stop],
                    %{duration: _, score: 100.0, total: 2, error_count: 0, save_as: nil},
                    %{evaluator: Evaluate, devset_size: 2, max_errors: _}}
  end

  test ":save_as writes JSON-Lines and stamps the path on stop measurements" do
    Mimic.stub(Dsxir.LM.Sycophant, :generate_text, fn _c, _msgs, _opts ->
      {:ok, "[[ ## a ## ]]\nok", Dsxir.LM.empty_usage()}
    end)

    path = Path.join(System.tmp_dir!(), "dsxir-eval-#{:erlang.unique_integer([:positive])}.jsonl")
    on_exit(fn -> File.rm(path) end)

    parent = self()
    ref = make_ref()
    handler_id = {__MODULE__, ref}

    :telemetry.attach(
      handler_id,
      [:dsxir, :evaluate, :stop],
      &TelemetryHandler.forward/4,
      %{parent: parent, tag: ref}
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      ev = %Evaluate{devset: [ex("q1", "ok")], metric: &metric/3, save_as: path}
      _ = Evaluate.run(ev, Dsxir.Program.new(Prog))
    end)

    assert File.exists?(path)
    [line | _] = File.read!(path) |> String.split("\n", trim: true)
    decoded = Jason.decode!(line)
    assert decoded["metric"] == 1.0
    assert decoded["error"] == nil

    assert_receive {^ref, _, %{save_as: ^path}, _}
  end

  test ":save_as writes one line per devset row" do
    Mimic.stub(Dsxir.LM.Sycophant, :generate_text, fn _c, _msgs, _opts ->
      {:ok, "[[ ## a ## ]]\nok", Dsxir.LM.empty_usage()}
    end)

    path = Path.join(System.tmp_dir!(), "dsxir-eval-#{:erlang.unique_integer([:positive])}.jsonl")
    on_exit(fn -> File.rm(path) end)

    Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      ev = %Evaluate{
        devset: Enum.map(1..3, &ex("q#{&1}", "ok")),
        metric: &metric/3,
        save_as: path
      }

      _ = Evaluate.run(ev, Dsxir.Program.new(Prog))
    end)

    lines = File.read!(path) |> String.split("\n", trim: true)
    assert length(lines) == 3
  end

  test "errors.by_module counts the concrete exception structs" do
    Mimic.stub(Dsxir.LM.Sycophant, :generate_text, fn _c, _msgs, _opts ->
      {:ok, "no markers", Dsxir.LM.empty_usage()}
    end)

    Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      ev = %Evaluate{
        devset: Enum.map(1..3, &ex("q#{&1}", "ok")),
        metric: &metric/3,
        num_threads: 2
      }

      result = Evaluate.run(ev, Dsxir.Program.new(Prog))

      assert result.errors.count == 3
      assert Enum.sum(Map.values(result.errors.by_module)) == 3

      assert Enum.all?(Map.keys(result.errors.by_module), fn mod ->
               function_exported?(mod, :__struct__, 0)
             end)
    end)
  end

  test "errors.samples carries deduped, bounded structs with truncated messages" do
    Mimic.stub(Dsxir.LM.Sycophant, :generate_text, fn _c, _msgs, _opts ->
      {:ok, "no markers", Dsxir.LM.empty_usage()}
    end)

    Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      ev = %Evaluate{
        devset: Enum.map(1..12, &ex("q#{&1}", "ok")),
        metric: &metric/3,
        num_threads: 4
      }

      result = Evaluate.run(ev, Dsxir.Program.new(Prog))

      assert result.errors.count == 12
      # all 12 rows fail identically -> one distinct sample
      assert [%{module: mod, class: class, message: message}] = result.errors.samples
      assert is_atom(mod)
      assert class == :adapter
      assert is_binary(message)
      assert String.length(message) <= 500
    end)
  end

  @tag :capture_log
  test "an undefined-function crash in the metric surfaces as Framework.UndefinedFunction" do
    Mimic.stub(Dsxir.LM.Sycophant, :generate_text, fn _c, _msgs, _opts ->
      {:ok, "[[ ## a ## ]]\nok", Dsxir.LM.empty_usage()}
    end)

    # built at runtime so the missing module is not a compile-time reference;
    # the call still exits with `:undef` at runtime.
    missing_mod = Module.concat([Dsxir, NoSuchModuleXYZ])
    undef_metric = fn _e, _p, _t -> missing_mod.score(1, 2) end

    Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      ev = %Evaluate{devset: [ex("q1", "ok")], metric: undef_metric, num_threads: 1}
      result = Evaluate.run(ev, Dsxir.Program.new(Prog))

      assert result.errors.count == 1
      assert %{Dsxir.Errors.Framework.UndefinedFunction => 1} = result.errors.by_module

      assert [%{error: %Dsxir.Errors.Framework.UndefinedFunction{} = err}] = result.results
      assert err.module == Dsxir.NoSuchModuleXYZ
      assert err.function == :score
      assert err.arity == 2
    end)
  end

  test "run!/2 raised reason carries the first error sample" do
    Mimic.stub(Dsxir.LM.Sycophant, :generate_text, fn _c, _msgs, _opts ->
      {:ok, "no markers", Dsxir.LM.empty_usage()}
    end)

    Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      ev = %Evaluate{devset: [ex("q1", "ok")], metric: &metric/3, num_threads: 1}

      err =
        assert_raise Dsxir.Errors.Framework.PredictorError, fn ->
          Evaluate.run!(ev, Dsxir.Program.new(Prog))
        end

      assert {:per_example_errors, 1, _by_class, %{module: _, message: _}} = err.reason
    end)
  end

  test "Inspect renders the first error sample on the headline" do
    Mimic.stub(Dsxir.LM.Sycophant, :generate_text, fn _c, _msgs, _opts ->
      {:ok, "no markers", Dsxir.LM.empty_usage()}
    end)

    Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      ev = %Evaluate{devset: [ex("q1", "ok")], metric: &metric/3, num_threads: 1}
      result = Evaluate.run(ev, Dsxir.Program.new(Prog))

      rendered = inspect(result)
      assert rendered =~ "errors: 1"
      assert rendered =~ "adapter:"
      assert rendered =~ "Adapter."
    end)
  end

  test "run/2 dispatches a runtime-program through Program.forward/2 without crashing" do
    Mimic.stub(Dsxir.LM.Sycophant, :generate_text, fn _c, _msgs, _opts ->
      {:ok, "[[ ## answer ## ]]\nok", Dsxir.LM.empty_usage()}
    end)

    rp = Dsxir.Test.Fixtures.RuntimePrograms.linear_chain_live()
    prog = Dsxir.Program.from_runtime(rp)

    devset =
      Enum.map(1..3, fn i ->
        Dsxir.Example.new(%{question: "q-#{i}", answer: "ok"}, input_keys: [:question])
      end)

    runtime_metric = fn _ex, %Dsxir.Prediction{fields: %{answer: a}}, _t ->
      if a == "ok", do: 1.0, else: 0.0
    end

    Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      ev = %Evaluate{devset: devset, metric: runtime_metric, num_threads: 1}
      assert %EvaluationResult{score: 100.0, errors: %{count: 0}} = Evaluate.run(ev, prog)
    end)
  end
end
