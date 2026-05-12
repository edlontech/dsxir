defmodule Dsxir.Test.TelemetryHandler do
  @moduledoc false

  def forward(event, measurements, metadata, %{parent: pid, tag: tag}) do
    send(pid, {tag, event, measurements, metadata})
  end
end
