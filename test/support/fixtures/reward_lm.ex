defmodule Dsxir.Test.Fixtures.RewardSig do
  @moduledoc false
  use Dsxir.Signature

  signature do
    instruction("baseline-instruction")
    input(:question, :string)
    output(:answer, :string)
  end
end

defmodule Dsxir.Test.Fixtures.RewardProgram do
  @moduledoc """
  Reward-shaped fixture program used to exercise `Dsxir.Optimizer.MIPROv2`
  without spinning up a real LM.

  `forward/2` reads the active `instructions_override` and demo bundle from
  the predictor state and produces a prediction whose `:answer` field encodes
  both. A companion metric (`reward_metric/3`) scores high when the active
  instruction matches a target string and/or the demo bundle is non-empty.

  When `Dsxir.Settings.resolve(:lm)` is configured the program also issues an
  LM call so the `Dsxir.Optimizer.Cache` and tenant-isolation paths get
  exercised. The LM result itself is discarded.
  """
  use Dsxir.Module

  alias Dsxir.Prediction
  alias Dsxir.Program

  predictor(:answer, Dsxir.Predictor.Predict, signature: Dsxir.Test.Fixtures.RewardSig)

  def forward(%Program{} = prog, %{question: q}) do
    state = Program.get_state(prog, :answer)

    _ =
      case Dsxir.Settings.resolve(:lm) do
        {mod, cfg} when is_atom(mod) and is_list(cfg) ->
          mod.generate_text(cfg, [%{role: "user", content: q}], [])

        _ ->
          :no_lm
      end

    tenant = Dsxir.Settings.resolve(:metadata, %{}) |> Map.get(:tenant_id, "anonymous")

    answer =
      "inst=#{state.instructions_override || "nil"};demos=#{length(state.demos)};tenant=#{tenant}"

    {prog, Prediction.new(%{answer: answer})}
  end
end

defmodule Dsxir.Test.Fixtures.RewardLM do
  @moduledoc """
  Test LM that returns a configurable canned response. Optional
  `config[:recorder_table]` records each call with the active tenant id and
  api key. Optional `config[:tenant_isolation_check]` records the resolved
  tenant id from settings inside the worker so the test can assert that the
  snapshot replay reached the trial workers.
  """
  @behaviour Dsxir.LM

  @impl Dsxir.LM
  def generate_text(config, _messages, _opts) do
    tenant =
      Dsxir.Settings.resolve(:metadata, %{}) |> Map.get(:tenant_id, "anonymous")

    case Keyword.get(config, :recorder_table) do
      nil ->
        :ok

      table ->
        :ets.insert(
          table,
          {make_ref(), tenant, Keyword.get(config, :api_key), self()}
        )
    end

    reply = Keyword.get(config, :reply, "[[ ## answer ## ]]\nok")
    {:ok, reply, Dsxir.LM.empty_usage()}
  end

  @impl Dsxir.LM
  def generate_object(_config, _messages, _schema, _opts) do
    {:ok, %{}, Dsxir.LM.empty_usage()}
  end
end
