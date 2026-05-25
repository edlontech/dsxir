defmodule Dsxir.Predictor.CodeExec.ToolBridgeTest do
  use ExUnit.Case, async: false

  alias Dsxir.Predictor.CodeExec.Sandbox
  alias Dsxir.Predictor.CodeExec.ToolAllowlist
  alias Dsxir.Predictor.CodeExec.ToolBridge
  alias Dsxir.Primitives.Tool

  defp double_tool do
    %Tool{
      name: "double",
      description: "Doubles a number.",
      parameters: Zoi.object(%{n: Zoi.integer()}),
      function: fn %{n: n} -> n * 2 end
    }
  end

  test "build returns a token, prelude fragment, and registers tools" do
    {token, prelude, prompt} = ToolBridge.build([double_tool()])
    assert is_binary(token)
    assert prelude =~ token
    assert prompt =~ "double"
  after
    ToolBridge.cleanup_all()
  end

  test "prompt instructs the fully-qualified dispatcher the sandbox accepts" do
    {_token, prelude, prompt} = ToolBridge.build([double_tool()])

    assert prompt =~ "Dsxir.Predictor.CodeExec.ToolBridge.call(__dsxir_tools__, name, args)"

    code =
      ~s|#{prelude}\nDsxir.Predictor.CodeExec.ToolBridge.call(__dsxir_tools__, "double", %{n: 21})|

    assert {:ok, %{value: "42"}} = Sandbox.eval(code, [], allowlist: ToolAllowlist)
  after
    ToolBridge.cleanup_all()
  end

  test "sandboxed code can call a registered tool via the dispatcher" do
    {_token, prelude, _prompt} = ToolBridge.build([double_tool()])

    code =
      ~s|#{prelude}\nDsxir.Predictor.CodeExec.ToolBridge.call(__dsxir_tools__, "double", %{n: 21})|

    assert {:ok, %{value: "42"}} = Sandbox.eval(code, [], allowlist: ToolAllowlist)
  after
    ToolBridge.cleanup_all()
  end

  test "unknown tool name returns a descriptive string" do
    {_token, prelude, _prompt} = ToolBridge.build([double_tool()])

    code =
      ~s|#{prelude}\nDsxir.Predictor.CodeExec.ToolBridge.call(__dsxir_tools__, "missing", %{})|

    assert {:ok, %{value: "Unknown tool: missing"}} =
             Sandbox.eval(code, [], allowlist: ToolAllowlist)
  after
    ToolBridge.cleanup_all()
  end

  test "a tool whose function raises returns an execution-error string" do
    boom_tool = %Tool{
      name: "boom",
      description: "Always explodes.",
      parameters: Zoi.object(%{}),
      function: fn _ -> raise "kaboom" end
    }

    {_token, prelude, _prompt} = ToolBridge.build([boom_tool])

    code =
      ~s|#{prelude}\nDsxir.Predictor.CodeExec.ToolBridge.call(__dsxir_tools__, "boom", %{})|

    assert {:ok, %{value: value}} = Sandbox.eval(code, [], allowlist: ToolAllowlist)
    assert value =~ "Execution error in"
    assert value =~ "boom"
  after
    ToolBridge.cleanup_all()
  end

  test "the bridge does not widen the allowlist beyond the dispatcher" do
    assert {:error, %{type: :restricted}} =
             Sandbox.eval(~s|File.read!("/etc/passwd")|, [], allowlist: ToolAllowlist)
  end
end
