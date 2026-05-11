defmodule Dsxir.Test.Fixtures.ObjectCapableLM do
  @moduledoc false
  @behaviour Dsxir.LM

  @impl Dsxir.LM
  def generate_text(_config, _messages, _opts) do
    {:ok, "text-response", Dsxir.LM.empty_usage()}
  end

  @impl Dsxir.LM
  def generate_object(_config, _messages, _schema, _opts) do
    {:ok, %{answer: "object-response"}, Dsxir.LM.empty_usage()}
  end
end
