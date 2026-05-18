defmodule Dsxir.DemoStrategy.KNN.EmbedTextTest do
  use ExUnit.Case, async: true

  alias Dsxir.DemoStrategy.KNN.EmbedText

  test ":all sorts keys alphabetically" do
    assert EmbedText.render(%{question: "q", context: "c"}, :all) ==
             "context: c\nquestion: q\n"
  end

  test "explicit fields preserve declaration order" do
    assert EmbedText.render(%{a: 1, b: 2, c: 3}, [:c, :a]) == "c: 3\na: 1\n"
  end

  test "missing field renders as nil, does not raise" do
    assert EmbedText.render(%{a: 1}, [:a, :missing]) == "a: 1\nmissing: nil\n"
  end

  test "string and atom and number values render directly" do
    assert EmbedText.render(%{a: "hi", b: :ok, c: 42, d: 3.14}, :all) ==
             "a: hi\nb: ok\nc: 42\nd: 3.14\n"
  end

  test "list and map values render as JSON" do
    assert EmbedText.render(%{items: ["a", "b"]}, [:items]) == "items: [\"a\",\"b\"]\n"
    assert EmbedText.render(%{m: %{x: 1}}, [:m]) == "m: {\"x\":1}\n"
  end

  test "opaque struct raises Invalid.Configuration with :unembeddable_input reason" do
    err =
      assert_raise Dsxir.Errors.Invalid.Configuration, fn ->
        EmbedText.render(%{a: %URI{}}, :all)
      end

    assert err.reason == :unembeddable_input
    assert err.key == :embed_inputs
  end

  test "deterministic — identical inputs produce identical output" do
    inputs = %{a: 1, b: [1, 2, 3], c: "x"}
    run1 = EmbedText.render(inputs, :all)
    run2 = EmbedText.render(inputs, :all)
    assert run1 == run2
  end
end
