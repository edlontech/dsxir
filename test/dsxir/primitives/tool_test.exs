defmodule Dsxir.Primitives.ToolTest do
  use ExUnit.Case, async: true

  alias Dsxir.Errors.Invalid
  alias Dsxir.Primitives.Tool

  defp calculator do
    Tool.new(
      name: "calculator",
      description: "Evaluate arithmetic",
      parameters: Zoi.object(%{expression: Zoi.string()}),
      function: fn %{expression: e} -> Code.eval_string(e) |> elem(0) |> to_string() end
    )
  end

  test "execute/2 returns {:ok, string} on a valid call" do
    assert {:ok, "4"} = Tool.execute(calculator(), %{expression: "2 + 2"})
  end

  test "execute/2 catches function exceptions and returns invalid tool error" do
    tool =
      Tool.new(
        name: "boom",
        description: "Raises",
        parameters: Zoi.object(%{}),
        function: fn _ -> raise "oops" end
      )

    assert {:error, %Invalid.Tool{tool: "boom", reason: :execution_error, inner: msg}} =
             Tool.execute(tool, %{})

    assert msg =~ "oops"
  end

  test "execute/2 short-circuits on Zoi validation failure" do
    assert {:error, %Invalid.Tool{tool: "calculator", reason: :argument_validation}} =
             Tool.execute(calculator(), %{expression: 42})
  end

  test "to_sycophant_tool/1 omits the function so Sycophant does not auto-execute" do
    syc = Tool.to_sycophant_tool(calculator())
    assert %Sycophant.Tool{name: "calculator", function: nil, schema_source: :zoi} = syc
  end
end
