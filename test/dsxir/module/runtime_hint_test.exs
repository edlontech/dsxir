defmodule Dsxir.Module.RuntimeHintTest do
  use ExUnit.Case, async: true

  alias Dsxir.Prediction
  alias Dsxir.Program.State

  defmodule RecordingPredictor do
    @moduledoc false
    @behaviour Dsxir.Predictor

    @impl Dsxir.Predictor
    def forward(%State{} = state, _signature, _inputs, opts) do
      send(self(), {:opts, opts})
      {state, Prediction.new(%{answer: "ok"})}
    end
  end

  defmodule HintProgram do
    @moduledoc false
    use Dsxir.Module

    predictor :my_pred, RecordingPredictor, signature: Dsxir.Test.Fixtures.AnswerQuestion

    def forward(prog, %{question: q}), do: call(prog, :my_pred, %{question: q})
  end

  setup do
    prior = Dsxir.Settings.snapshot()
    on_exit(fn -> :persistent_term.put({Dsxir.Settings, :globals}, prior.globals) end)
    :ok
  end

  defp recorded_opts(frame) do
    prog = Dsxir.Program.new(HintProgram)

    Dsxir.Settings.context(frame, fn ->
      HintProgram.forward(prog, %{question: "ultimate?"})
    end)

    receive do
      {:opts, opts} -> opts
    after
      0 -> flunk("predictor forward/4 was not invoked")
    end
  end

  test "active hint for the predictor is passed as opts[:hint]" do
    opts = recorded_opts(hints: %{my_pred: "advice text"})

    assert Keyword.get(opts, :hint) == "advice text"
  end

  test "empty-string hint for the predictor is not passed as opts[:hint]" do
    opts = recorded_opts(hints: %{my_pred: ""})

    refute Keyword.has_key?(opts, :hint)
  end

  test "absent hint for the predictor is not passed as opts[:hint]" do
    opts = recorded_opts([])

    refute Keyword.has_key?(opts, :hint)
  end

  test "hint targeting a different predictor is not passed as opts[:hint]" do
    opts = recorded_opts(hints: %{other_pred: "advice text"})

    refute Keyword.has_key?(opts, :hint)
  end
end
