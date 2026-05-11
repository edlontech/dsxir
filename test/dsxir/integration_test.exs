defmodule Dsxir.IntegrationTest do
  @moduledoc """
  Live LM smoke test. Excluded from the default mix test run; opt in via
  `mix test --include integration`. Requires OPENAI_API_KEY in the environment.
  """

  use ExUnit.Case, async: false

  alias Dsxir.Test.Fixtures.AnswerProgram

  @moduletag :integration

  test "AnswerProgram answers a factual question via gpt-4o-mini" do
    case System.get_env("OPENAI_API_KEY") do
      api_key when api_key in [nil, ""] ->
        IO.warn("skipping live test: OPENAI_API_KEY not set")

      api_key ->
        Dsxir.context(
          [
            lm:
              {Dsxir.LM.Sycophant,
               [model: "openai:gpt-4o-mini", api_key: api_key, temperature: 0.0]}
          ],
          fn ->
            prog = Dsxir.Program.new(AnswerProgram)

            {_prog2, prediction} =
              AnswerProgram.forward(prog, %{question: "What is the capital of France?"})

            assert %Dsxir.Prediction{} = prediction
            assert is_binary(prediction[:answer])
            assert prediction[:answer] =~ ~r/Paris/i
          end
        )
    end
  end
end
