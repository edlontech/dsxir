defmodule Dsxir.Integration.RuntimeProgramLiveTest do
  @moduledoc """
  End-to-end smoke test for a runtime-authored program against the live
  Sycophant LM. Excluded by default via `@moduletag :integration`; run with
  `mix test --include integration` (or `mix test.integration`). Requires the
  relevant provider API key for the configured model to be present in the
  environment.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias Dsxir.Prediction
  alias Dsxir.Program
  alias Dsxir.Test.Fixtures.RuntimePrograms

  test "runtime program executes end-to-end against Sycophant" do
    case System.get_env("ANTHROPIC_API_KEY") do
      key when is_binary(key) and key != "" ->
        rp = RuntimePrograms.linear_chain_live()
        prog = Program.from_runtime(rp)
        model = System.get_env("DSXIR_TEST_MODEL", "anthropic:claude-haiku-4-5")

        Dsxir.Settings.context(
          [lm: {Dsxir.LM.Sycophant, [model: model, api_key: key]}],
          fn ->
            assert {%Program{}, %Prediction{fields: fields}} =
                     Program.forward(prog, %{question: "What is 2+2?"})

            assert is_binary(fields[:answer])
            assert fields[:answer] != ""
          end
        )

      _ ->
        IO.puts("\n  -> SKIPPED: ANTHROPIC_API_KEY not set")
        :ok
    end
  end
end
