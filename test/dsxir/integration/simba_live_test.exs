defmodule Dsxir.Integration.SIMBALiveTest do
  @moduledoc """
  Live-LM acceptance for SIMBA. Tagged `:integration` and excluded from the
  default `mix test` run. Opt in with `mix test.integration` or
  `mix test --include integration test/dsxir/integration/simba_live_test.exs`.

  Requires `OPENAI_API_KEY` in the environment; when missing the test is
  skipped (matches the pattern used by other live tests so CI without
  credentials does not abort the suite).

  Runs `auto: :light` against the real `Dsxir.LM.Sycophant` over a tiny
  synthetic trainset with a deterministic string-equality metric. Asserts clean
  termination and a float `best_score`; does not assert any score ordering.
  """

  use ExUnit.Case, async: false

  alias Dsxir.Optimizer.SIMBA
  alias Dsxir.Optimizer.SIMBA.Stats
  alias Dsxir.Prediction
  alias Dsxir.Program
  alias Dsxir.Settings

  @moduletag :integration
  @moduletag timeout: 600_000

  @model "openai:gpt-4o-mini"

  setup_all do
    case System.get_env("OPENAI_API_KEY") do
      key when is_binary(key) and key != "" ->
        Dsxir.configure(adapter: Dsxir.Adapter.Chat)
        {:ok, api_key: key}

      _ ->
        {:skip, "OPENAI_API_KEY not set"}
    end
  end

  defmodule Sig do
    @moduledoc "Echo the given word back verbatim."
    use Dsxir.Signature

    signature do
      input(:word, :string)
      output(:echo, :string)
    end
  end

  defmodule Echo do
    @moduledoc false
    use Dsxir.Module

    predictor(:say, Dsxir.Predictor.Predict, signature: Sig)

    def forward(prog, %{word: w}), do: call(prog, :say, %{word: w})
  end

  defp trainset do
    for w <- ~w(alpha bravo charlie delta echo foxtrot) do
      Dsxir.Example.new(%{word: w, echo: w}, input_keys: [:word])
    end
  end

  defp metric(
         %Dsxir.Example{data: %{echo: expected}},
         %Prediction{fields: %{echo: actual}},
         _trace
       )
       when is_binary(actual) do
    if String.trim(actual) == expected, do: 1.0, else: 0.0
  end

  defp metric(_ex, _pred, _trace), do: 0.0

  test "SIMBA compiles cleanly against a live LM", ctx do
    with_lm(ctx.api_key, fn ->
      assert {:ok, %Program{} = compiled, %Stats{} = stats} =
               Dsxir.compile(SIMBA, Program.new(Echo), trainset(), &metric/3,
                 auto: :light,
                 bsize: 4,
                 max_steps: 2,
                 num_candidates: 2,
                 seed: 7
               )

      assert is_float(stats.best_score)
      assert stats.steps == 2
      assert compiled.metadata.compiled_with == SIMBA
    end)
  end

  defp with_lm(api_key, fun) do
    Settings.context(
      [lm: {Dsxir.LM.Sycophant, [model: @model, api_key: api_key, temperature: 0.0]}],
      fun
    )
  end
end
