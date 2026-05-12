defmodule Dsxir.DemoTest do
  use ExUnit.Case, async: true

  test "labeled/1 wraps an Example with kind :labeled and source nil" do
    ex = Dsxir.Example.new(%{q: "x", a: "y"}, input_keys: [:q])
    assert %Dsxir.Demo{example: ^ex, kind: :labeled, source: nil} = Dsxir.Demo.labeled(ex)
  end

  test "bootstrapped/2 records source" do
    ex = Dsxir.Example.new(%{q: "x", a: "y"}, input_keys: [:q])
    src = %{round: 2, example_index: 7}

    assert %Dsxir.Demo{example: ^ex, kind: :bootstrapped, source: ^src} =
             Dsxir.Demo.bootstrapped(ex, src)
  end
end
