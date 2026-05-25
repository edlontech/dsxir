defmodule Dsxir.Predictor.CodeExec.SandboxTest do
  use ExUnit.Case, async: true

  alias Dsxir.Predictor.CodeExec.Sandbox

  test "evaluates a returning expression" do
    assert {:ok, %{value: 3, inspected: "3"}} = Sandbox.eval("1 + 2", [], [])
  end

  test "binds inputs as a prelude" do
    assert {:ok, %{value: 7}} = Sandbox.eval("a + b", [a: 3, b: 4], [])
  end

  test "binds non-scalar inputs" do
    assert {:ok, %{value: 2}} = Sandbox.eval("length(items)", [items: [:x, :y]], [])
  end

  test "classifies restricted calls" do
    assert {:error, %{type: :restricted}} = Sandbox.eval(~s|File.read!("/etc/passwd")|, [], [])
  end

  test "classifies timeouts" do
    assert {:error, %{type: :timeout}} =
             Sandbox.eval("Process.sleep(500)", [], exec_timeout: 50)
  end

  test "classifies runtime exceptions" do
    assert {:error, %{type: :exception}} = Sandbox.eval("raise \"boom\"", [], [])
  end

  test "classifies parse errors" do
    assert {:error, %{type: :parsing}} = Sandbox.eval("][", [], [])
  end
end
