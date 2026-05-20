defmodule Dsxir.Errors.GEPAErrorsTest do
  use ExUnit.Case, async: true

  alias Dsxir.Errors

  test "EmptyDevset has :invalid class and useful message" do
    e = %Errors.Invalid.EmptyDevset{
      reason: :too_small,
      trainset_size: 1,
      devset_fraction: 0.3
    }

    assert e.class == :invalid
    msg = Exception.message(e)
    assert msg =~ "1 trainset examples"
    assert msg =~ "0.3"
  end

  test "GEPAOperatorFailed has :framework class and parent error round-trips" do
    inner = %RuntimeError{message: "boom"}

    e = %Errors.Framework.GEPAOperatorFailed{
      operator: :mutate_instr,
      parents: ["ind_x"],
      reason: :stale_parent_ref,
      parent_error: inner
    }

    assert e.class == :framework
    assert Exception.message(e) =~ ":mutate_instr"
    assert e.parent_error == inner
  end

  test "class_of/1 classifies both" do
    assert Errors.class_of(%Errors.Invalid.EmptyDevset{
             reason: :too_small,
             trainset_size: 0,
             devset_fraction: 0.3
           }) == :invalid

    assert Errors.class_of(%Errors.Framework.GEPAOperatorFailed{
             operator: :crossover,
             parents: [],
             reason: :test,
             parent_error: nil
           }) == :framework
  end
end
