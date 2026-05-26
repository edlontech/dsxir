defmodule Dsxir.TelemetryTest do
  use ExUnit.Case, async: true

  alias Dsxir.Telemetry
  alias Dsxir.Test.TelemetryHandler

  test "emit/3 fires :telemetry.execute on the documented event name" do
    parent = self()
    ref = make_ref()
    handler_id = {__MODULE__, ref}
    event = [:dsxir, :_test]

    :ok =
      :telemetry.attach(
        handler_id,
        event,
        &TelemetryHandler.forward/4,
        %{parent: parent, tag: ref}
      )

    try do
      Dsxir.Telemetry.emit(event, %{duration: 1}, %{tag: :sentinel})
      assert_receive {^ref, ^event, %{duration: 1}, %{tag: :sentinel}}, 200
    after
      :telemetry.detach(handler_id)
    end
  end

  test "event-name accessors return the documented lists" do
    assert Dsxir.Telemetry.predictor_start() == [:dsxir, :predictor, :start]
    assert Dsxir.Telemetry.predictor_stop() == [:dsxir, :predictor, :stop]
    assert Dsxir.Telemetry.predictor_exception() == [:dsxir, :predictor, :exception]
    assert Dsxir.Telemetry.adapter_format() == [:dsxir, :adapter, :format]
    assert Dsxir.Telemetry.adapter_parse() == [:dsxir, :adapter, :parse]
    assert Dsxir.Telemetry.adapter_fallback() == [:dsxir, :adapter, :fallback]
    assert Dsxir.Telemetry.optimizer_start() == [:dsxir, :optimizer, :start]
    assert Dsxir.Telemetry.optimizer_stop() == [:dsxir, :optimizer, :stop]
    assert Dsxir.Telemetry.optimizer_trial() == [:dsxir, :optimizer, :trial]
    assert Dsxir.Telemetry.optimizer_item_error() == [:dsxir, :optimizer, :item_error]
    assert Dsxir.Telemetry.evaluate_item() == [:dsxir, :evaluate, :item]
    assert Dsxir.Telemetry.evaluate_stop() == [:dsxir, :evaluate, :stop]

    assert Dsxir.Telemetry.predictor_code_exec_attempt() == [
             :dsxir,
             :predictor,
             :code_exec,
             :attempt
           ]
  end

  test "ensemble event-name helpers" do
    assert Telemetry.ensemble_member() == [:dsxir, :predictor, :ensemble, :member]
    assert Telemetry.ensemble_stop() == [:dsxir, :predictor, :ensemble, :stop]
  end
end
