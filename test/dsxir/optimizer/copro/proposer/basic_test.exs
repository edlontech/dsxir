defmodule Dsxir.Optimizer.COPRO.Proposer.BasicTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Dsxir.Optimizer.COPRO.Proposer.Basic
  alias Dsxir.Test.Fixtures.AnswerQuestion

  setup :set_mimic_global

  setup do
    Mimic.copy(Dsxir.LM.Sycophant)
    :ok
  end

  defp decl, do: %{name: :answer, signature: AnswerQuestion}

  test "returns exactly n instructions including the current one" do
    expect(Dsxir.LM.Sycophant, :generate_text, fn _config, _msgs, _opts ->
      {:ok, "1. Be precise.\n2. Cite sources.\n3. Answer briefly.", Dsxir.LM.empty_usage()}
    end)

    ctx = %{
      kind: :basic,
      decl: decl(),
      current_instruction: "Answer the question.",
      n: 4,
      temperature: 1.0,
      lm: {Dsxir.LM.Sycophant, []}
    }

    assert {:ok, instrs} = Basic.run(ctx)
    assert length(instrs) == 4
    assert "Answer the question." in instrs
    assert "Be precise." in instrs
  end

  test "pads to n when the LM returns fewer lines" do
    expect(Dsxir.LM.Sycophant, :generate_text, fn _, _, _ ->
      {:ok, "Be precise.", Dsxir.LM.empty_usage()}
    end)

    ctx = %{
      kind: :basic,
      decl: decl(),
      current_instruction: "X",
      n: 4,
      temperature: 1.0,
      lm: {Dsxir.LM.Sycophant, []}
    }

    assert {:ok, instrs} = Basic.run(ctx)
    assert length(instrs) == 4
    assert "X" in instrs
  end

  test "treats a nil current instruction as an empty slot" do
    expect(Dsxir.LM.Sycophant, :generate_text, fn _, _, _ ->
      {:ok, "1. Be precise.", Dsxir.LM.empty_usage()}
    end)

    ctx = %{
      kind: :basic,
      decl: decl(),
      current_instruction: nil,
      n: 3,
      temperature: 1.0,
      lm: {Dsxir.LM.Sycophant, []}
    }

    assert {:ok, instrs} = Basic.run(ctx)
    assert length(instrs) == 3
    assert "" in instrs
  end

  test "passes the temperature through to the LM call" do
    expect(Dsxir.LM.Sycophant, :generate_text, fn _config, _msgs, opts ->
      assert Keyword.fetch!(opts, :temperature) == 1.4
      {:ok, "1. Be precise.", Dsxir.LM.empty_usage()}
    end)

    ctx = %{
      kind: :basic,
      decl: decl(),
      current_instruction: "X",
      n: 2,
      temperature: 1.4,
      lm: {Dsxir.LM.Sycophant, []}
    }

    assert {:ok, _} = Basic.run(ctx)
  end

  test "surfaces LM errors" do
    expect(Dsxir.LM.Sycophant, :generate_text, fn _, _, _ ->
      {:error, %Dsxir.Errors.LM.RateLimited{}}
    end)

    ctx = %{
      kind: :basic,
      decl: decl(),
      current_instruction: "X",
      n: 4,
      temperature: 1.0,
      lm: {Dsxir.LM.Sycophant, []}
    }

    assert {:error, %Dsxir.Errors.LM.RateLimited{}} = Basic.run(ctx)
  end
end
