defmodule Dsxir.LMTest do
  use ExUnit.Case, async: false

  defmodule StubImpl do
    @behaviour Dsxir.LM

    @impl Dsxir.LM
    def generate_text(config, messages, opts) do
      send(self(), {:stub_called, config, messages, opts})
      {:ok, "stub-response", Dsxir.LM.empty_usage()}
    end

    @impl Dsxir.LM
    def generate_object(config, messages, schema, opts) do
      send(self(), {:stub_object_called, config, messages, schema, opts})
      {:ok, %{answer: "stub-object"}, Dsxir.LM.empty_usage()}
    end
  end

  defmodule TextOnlyImpl do
    @behaviour Dsxir.LM

    @impl Dsxir.LM
    def generate_text(_config, _messages, _opts) do
      {:ok, "text-only", Dsxir.LM.empty_usage()}
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
      assert {:ok, "stub-response", %{tokens_in: nil, tokens_out: nil, cost: nil}} =
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

  test "@callback generate_object/4 is declared on the behaviour and optional" do
    callbacks = Dsxir.LM.behaviour_info(:callbacks)
    optional = Dsxir.LM.behaviour_info(:optional_callbacks)
    assert {:generate_object, 4} in callbacks
    assert {:generate_object, 4} in optional
  end

  test "generate_object/3 dispatches to impl when implemented" do
    schema = Zoi.object(%{answer: Zoi.string()})

    Dsxir.Settings.context([lm: {StubImpl, [model: "test-model"]}], fn ->
      assert {:ok, %{answer: "stub-object"}, %{tokens_in: nil, tokens_out: nil, cost: nil}} =
               Dsxir.LM.generate_object([%{role: "user", content: "hi"}], schema, [])
    end)

    assert_received {:stub_object_called, [model: "test-model"], [%{role: "user", content: "hi"}],
                     _schema, []}
  end

  test "generate_object/3 raises Invalid.Configuration when impl does not export it" do
    schema = Zoi.object(%{answer: Zoi.string()})

    Dsxir.Settings.context([lm: {TextOnlyImpl, [model: "m"]}], fn ->
      err =
        assert_raise Dsxir.Errors.Invalid.Configuration, fn ->
          Dsxir.LM.generate_object([], schema, [])
        end

      assert err.reason == :generate_object_unsupported
      assert err.value == TextOnlyImpl
    end)
  end

  test "generate_object/3 raises Invalid.Configuration when :lm is unset" do
    schema = Zoi.object(%{answer: Zoi.string()})

    assert_raise Dsxir.Errors.Invalid.Configuration, fn ->
      Dsxir.LM.generate_object([], schema, [])
    end
  end

  test "generate_object/3 raises Invalid.Configuration when :lm is malformed" do
    schema = Zoi.object(%{answer: Zoi.string()})

    Dsxir.Settings.context([lm: :not_a_tuple], fn ->
      assert_raise Dsxir.Errors.Invalid.Configuration, fn ->
        Dsxir.LM.generate_object([], schema, [])
      end
    end)
  end

  test "generate_object/3 loads the impl module before introspection when configured by atom only" do
    impl = Dsxir.Test.Fixtures.ObjectCapableLM
    schema = Zoi.object(%{answer: Zoi.string()})

    :code.purge(impl)
    :code.delete(impl)
    refute :code.is_loaded(impl)

    try do
      Dsxir.Settings.context([lm: {impl, [model: "stub"]}], fn ->
        assert {:ok, %{answer: "object-response"}, %{tokens_in: nil, tokens_out: nil, cost: nil}} =
                 Dsxir.LM.generate_object([%{role: "user", content: "hi"}], schema, [])
      end)
    after
      Code.ensure_loaded(impl)
    end
  end
end
