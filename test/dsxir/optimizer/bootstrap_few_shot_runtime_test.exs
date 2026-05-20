defmodule Dsxir.Optimizer.BootstrapFewShotRuntimeTest do
  use ExUnit.Case, async: false

  alias Dsxir.Artifact
  alias Dsxir.Optimizer.BootstrapFewShot
  alias Dsxir.Prediction
  alias Dsxir.Program
  alias Dsxir.Test.Fixtures.RuntimePrograms
  alias Dsxir.Test.Fixtures.ScriptedLM

  setup do
    ScriptedLM.clear_script()
    on_exit(&ScriptedLM.clear_script/0)
    :ok
  end

  test "BootstrapFewShot over a runtime program with optional fan-in" do
    install_diamond_script()

    rp = RuntimePrograms.diamond_with_optional_fan_in()
    prog = Program.from_runtime(rp)
    trainset = diamond_trainset()

    parent = self()
    handler_id = "insufficient-demos-#{:erlang.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:dsxir, :optimizer, :insufficient_demos],
      &Dsxir.Test.TelemetryHandler.forward/4,
      %{parent: parent, tag: :insufficient}
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, compiled, _stats} =
      BootstrapFewShot.compile(prog, trainset, &diamond_metric/3,
        max_labeled_demos: 0,
        max_bootstrapped_demos: 4,
        max_rounds: 1,
        threshold: 1.0,
        deterministic: true
      )

    extract = Program.get_state(compiled, :extract)
    assert length(extract.demos) == 4
    assert Enum.all?(extract.demos, &match?(%Dsxir.Demo{kind: :bootstrapped}, &1))

    route = Program.get_state(compiled, :route)
    assert length(route.demos) <= 3
    refute Enum.empty?(route.demos)
    assert Enum.all?(route.demos, &match?(%Dsxir.Demo{kind: :bootstrapped}, &1))

    merge = Program.get_state(compiled, :merge)
    assert length(merge.demos) <= 2
    refute Enum.empty?(merge.demos)
    assert Enum.all?(merge.demos, &match?(%Dsxir.Demo{kind: :bootstrapped}, &1))

    insufficient = drain_insufficient([])

    refute Enum.empty?(insufficient)

    assert Enum.any?(insufficient, fn meta ->
             meta.predictor == :route and meta.requested == 4 and meta.got < 4
           end)

    assert Enum.any?(insufficient, fn meta ->
             meta.predictor == :merge and meta.requested == 4 and meta.got < 4
           end)

    assert Enum.all?(insufficient, fn meta -> meta.degraded_excluded == true end)
    assert Enum.all?(insufficient, fn meta -> meta.total_examples == 6 end)
  end

  test "BootstrapFewShot includes degraded demos when degraded_demos: :include" do
    install_diamond_script()

    rp = RuntimePrograms.diamond_with_optional_fan_in()
    prog = Program.from_runtime(rp)
    trainset = diamond_trainset()

    {:ok, with_exclude, _} =
      BootstrapFewShot.compile(prog, trainset, &diamond_metric/3,
        max_labeled_demos: 0,
        max_bootstrapped_demos: 4,
        max_rounds: 1,
        threshold: 1.0,
        deterministic: true,
        degraded_demos: :exclude
      )

    {:ok, with_include, _} =
      BootstrapFewShot.compile(prog, trainset, &diamond_metric/3,
        max_labeled_demos: 0,
        max_bootstrapped_demos: 4,
        max_rounds: 1,
        threshold: 1.0,
        deterministic: true,
        degraded_demos: :include
      )

    excluded_merge = Program.get_state(with_exclude, :merge).demos
    included_merge = Program.get_state(with_include, :merge).demos

    assert length(included_merge) >= length(excluded_merge)
  end

  @tag :tmp_dir
  test "save!/load! round-trips the compiled runtime program", %{tmp_dir: tmp_dir} do
    install_diamond_script()

    rp = RuntimePrograms.diamond_with_optional_fan_in()
    prog = Program.from_runtime(rp)
    trainset = diamond_trainset()

    {:ok, compiled, _stats} =
      BootstrapFewShot.compile(prog, trainset, &diamond_metric/3,
        max_labeled_demos: 0,
        max_bootstrapped_demos: 4,
        max_rounds: 1,
        threshold: 1.0,
        deterministic: true
      )

    path = Path.join(tmp_dir, "diamond.json")
    assert ^path = Artifact.save!(compiled, path)
    loaded = Artifact.load!(Dsxir.Program, path)

    assert %Dsxir.Program.Source.RuntimeProgram{runtime_program: loaded_rp} = loaded.source
    assert loaded_rp.id == rp.id
    assert loaded_rp.version == rp.version

    for site_name <- [:extract, :route, :validate, :merge] do
      original_demos = Program.get_state(compiled, site_name).demos
      loaded_demos = Program.get_state(loaded, site_name).demos
      assert length(loaded_demos) == length(original_demos)
    end
  end

  defp drain_insufficient(acc) do
    receive do
      {:insufficient, [:dsxir, :optimizer, :insufficient_demos], _measurements, meta} ->
        drain_insufficient([meta | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp install_diamond_script do
    ScriptedLM.install_script(%{
      extract: fn inputs -> %{answer: "extracted-" <> Map.get(inputs, :question, "")} end,
      route: fn inputs -> %{answer: "routed-" <> to_string(Map.get(inputs, :question, ""))} end,
      validate: fn inputs ->
        %{answer: "validated-" <> to_string(Map.get(inputs, :question, ""))}
      end,
      merge: fn inputs -> %{answer: "merged-" <> to_string(Map.get(inputs, :question, ""))} end
    })
  end

  defp diamond_trainset do
    [
      ex("q1", true, true),
      ex("q2", true, true),
      ex("q3", true, false),
      ex("q4", false, false),
      ex("q5", false, false),
      ex("q6", false, true)
    ]
  end

  defp ex(question, go, check) do
    Dsxir.Example.new(
      %{question: question, go: go, check: check, answer: "ok"},
      input_keys: [:question, :go, :check]
    )
  end

  defp diamond_metric(_example, %Prediction{}, _trace), do: 1.0
end
