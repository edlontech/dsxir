defmodule Dsxir.TelemetryTest do
  use ExUnit.Case, async: true

  test "emit/3 fires :telemetry.execute on the documented event name" do
    parent = self()
    ref = make_ref()
    handler_id = {__MODULE__, ref}
    event = [:dsxir, :_test]

    :ok =
      :telemetry.attach(
        handler_id,
        event,
        fn ^event, measurements, metadata, _ ->
          send(parent, {ref, measurements, metadata})
        end,
        nil
      )

    try do
      Dsxir.Telemetry.emit(event, %{duration: 1}, %{tag: :sentinel})
      assert_receive {^ref, %{duration: 1}, %{tag: :sentinel}}, 200
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
  end
end
