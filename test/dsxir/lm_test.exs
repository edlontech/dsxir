defmodule Dsxir.LMTest do
  use ExUnit.Case, async: false

  defmodule StubImpl do
    @behaviour Dsxir.LM

    @impl Dsxir.LM
    def generate_text(config, messages, opts) do
      send(self(), {:stub_called, config, messages, opts})
      {:ok, "stub-response"}
    end
  end

  setup do
    prior = Dsxir.Settings.snapshot()
    :persistent_term.put({Dsxir.Settings, :globals}, Dsxir.Settings.default_globals())
    Process.delete({Dsxir.Settings, :stack})
    on_exit(fn -> :persistent_term.put({Dsxir.Settings, :globals}, prior.globals) end)
    :ok
  end

  test "@callback generate_text/3 is declared on the behaviour" do
    callbacks = Dsxir.LM.behaviour_info(:callbacks)
    assert {:generate_text, 3} in callbacks
  end

  test "generate_text/2 dispatches to the {impl, config} tuple resolved from settings" do
    Dsxir.Settings.context([lm: {StubImpl, [model: "test-model"]}], fn ->
      assert {:ok, "stub-response"} =
               Dsxir.LM.generate_text([%{role: "user", content: "hi"}], temperature: +0.0)
    end)

    assert_received {:stub_called, [model: "test-model"], [%{role: "user", content: "hi"}],
                     [temperature: +0.0]}
  end

  test "generate_text/2 raises Invalid.Configuration when :lm is unset" do
    assert_raise Dsxir.Errors.Invalid.Configuration, fn ->
      Dsxir.LM.generate_text([])
    end
  end

  test "generate_text/2 raises Invalid.Configuration when :lm is malformed" do
    Dsxir.Settings.context([lm: :not_a_tuple], fn ->
      assert_raise Dsxir.Errors.Invalid.Configuration, fn ->
        Dsxir.LM.generate_text([])
      end
    end)
  end
end
