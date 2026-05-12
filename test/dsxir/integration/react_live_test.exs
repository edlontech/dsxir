defmodule Dsxir.Integration.ReActLiveTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Dsxir.Predictor.ReAct
  alias Dsxir.Primitives.Tool

  defmodule QASig do
    use Dsxir.Signature

    signature do
      instruction "Answer the user's question using the available tools."
      input :question, :string
      output :answer, :string
    end
  end

  defp web_search do
    Tool.new(
      name: "web_search",
      description: "Search the web. Returns a short text snippet for the query.",
      parameters: Zoi.object(%{query: Zoi.string()}),
      function: fn %{query: q} ->
        if String.contains?(String.downcase(q), "france") do
          "Population of France (2024 estimate): 68,374,591."
        else
          "No relevant results."
        end
      end
    )
  end

  defp calculator do
    Tool.new(
      name: "calculator",
      description: "Evaluate an arithmetic expression and return the result as a string.",
      parameters: Zoi.object(%{expression: Zoi.string()}),
      function: fn %{expression: e} -> Code.eval_string(e) |> elem(0) |> to_string() end
    )
  end

  test "agent answers a multi-step question using web_search and calculator" do
    api_key = System.fetch_env!("OPENAI_API_KEY")

    Dsxir.Settings.context(
      [lm: {Dsxir.LM.Sycophant, [model: "openai:gpt-4o-mini", api_key: api_key]}],
      fn ->
        {_pstate, prediction} =
          ReAct.forward(
            %Dsxir.Program.State{demos: []},
            QASig,
            %{question: "What is 17% of the population of France?"},
            tools: [web_search(), calculator()],
            max_iters: 8,
            trace_name: :agent
          )

        assert is_binary(prediction.fields[:answer])
        assert prediction.fields[:answer] != ""

        trajectory = prediction.fields[:trajectory]
        tool_names = Enum.map(trajectory, & &1.tool_name)
        assert "finish" in tool_names
        assert "web_search" in tool_names or "calculator" in tool_names
      end
    )
  end
end
