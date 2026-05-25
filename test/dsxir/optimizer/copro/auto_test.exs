defmodule Dsxir.Optimizer.COPRO.AutoTest do
  use ExUnit.Case, async: true
  alias Dsxir.Optimizer.COPRO.Auto

  test "presets expose breadth/depth/init_temperature" do
    assert %{breadth: 4, depth: 2, init_temperature: 1.0} = Auto.preset(:light)
    assert %{breadth: 10, depth: 4} = Auto.preset(:heavy)
  end

  test "expand overlays user opts over preset" do
    assert %{breadth: 20, depth: 3, init_temperature: 1.2} =
             Auto.expand([breadth: 20], :medium)
  end

  test "expand ignores unrelated opts" do
    assert %{breadth: 6} = Auto.expand([proposer_lm: {Mod, []}], :medium)
  end
end
