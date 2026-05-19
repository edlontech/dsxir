defmodule Dsxir.Test.Fixtures.StubProposerLM do
  @moduledoc """
  Test LM that returns whatever binary is supplied via `config[:reply]`. Used
  to exercise proposer modules without a network call.
  """

  @behaviour Dsxir.LM

  @impl Dsxir.LM
  def generate_text(config, _messages, _opts) do
    {:ok, Keyword.get(config, :reply, ""), Dsxir.LM.empty_usage()}
  end

  @impl Dsxir.LM
  def generate_object(_config, _messages, _schema, _opts) do
    {:ok, %{}, Dsxir.LM.empty_usage()}
  end
end

defmodule Dsxir.Test.Fixtures.FailingProposerLM do
  @moduledoc """
  Test LM that always returns `{:error, %RuntimeError{}}`. Used to exercise the
  degraded paths of proposer modules.
  """

  @behaviour Dsxir.LM

  @impl Dsxir.LM
  def generate_text(_config, _messages, _opts) do
    {:error, %RuntimeError{message: "proposer down"}}
  end

  @impl Dsxir.LM
  def generate_object(_config, _messages, _schema, _opts) do
    {:error, %RuntimeError{message: "proposer down"}}
  end
end
