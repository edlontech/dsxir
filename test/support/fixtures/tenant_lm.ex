defmodule Dsxir.Test.Fixtures.TenantLM do
  @moduledoc """
  Test-only LM impl that records per-tenant API key + call counters into an
  ETS table named by the test. The table is created by the test and passed
  into the impl via config; the impl reads it back from config and writes
  one row per call.
  """

  @behaviour Dsxir.LM

  @impl Dsxir.LM
  def generate_text(config, _messages, _opts) do
    tenant_id =
      Dsxir.Settings.resolve(:metadata, %{}) |> Map.get(:tenant_id, "anonymous")

    table = Keyword.fetch!(config, :recorder_table)
    api_key = Keyword.get(config, :api_key)

    :ets.insert(table, {make_ref(), tenant_id, api_key, System.monotonic_time()})

    response = "[[ ## answer ## ]]\nresponse-for-#{tenant_id}"
    {:ok, response, Dsxir.LM.empty_usage()}
  end
end
