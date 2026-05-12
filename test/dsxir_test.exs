defmodule DsxirTest do
  use ExUnit.Case, async: true

  test "configure/1, context/2, evaluate/2, compile/5, save/2, load/3 are exported" do
    exported = Dsxir.__info__(:functions)
    assert {:configure, 1} in exported
    assert {:context, 2} in exported
    assert {:evaluate, 2} in exported
    assert {:evaluate!, 2} in exported
    assert {:compile, 5} in exported
    assert {:save, 2} in exported
    assert {:save!, 2} in exported
    assert {:load, 2} in exported
    assert {:load, 3} in exported
    assert {:load!, 2} in exported
    assert {:load!, 3} in exported
  end
end
