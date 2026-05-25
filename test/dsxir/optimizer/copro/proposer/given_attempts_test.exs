defmodule Dsxir.Optimizer.COPRO.Proposer.GivenAttemptsTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Dsxir.Optimizer.COPRO.Proposer.GivenAttempts
  alias Dsxir.Test.Fixtures.AnswerQuestion

  setup :set_mimic_global

  setup do
    Mimic.copy(Dsxir.LM.Sycophant)
    :ok
  end

  defp decl, do: %{name: :answer, signature: AnswerQuestion}

  defp attempts do
    [
      %{instruction: "Best so far.", score: 0.9},
      %{instruction: "Mediocre attempt.", score: 0.5},
      %{instruction: "Worst attempt.", score: 0.1}
    ]
  end

  test "returns exactly n instructions" do
    expect(Dsxir.LM.Sycophant, :generate_text, fn _, _, _ ->
      {:ok, "1. Be precise.\n2. Cite sources.", Dsxir.LM.empty_usage()}
    end)

    ctx = %{
      kind: :given_attempts,
      decl: decl(),
      attempts: attempts(),
      n: 4,
      temperature: 1.2,
      lm: {Dsxir.LM.Sycophant, []}
    }

    assert {:ok, instrs} = GivenAttempts.run(ctx)
    assert length(instrs) == 4
  end

  test "pads shortfall with the best attempt's instruction" do
    expect(Dsxir.LM.Sycophant, :generate_text, fn _, _, _ ->
      {:ok, "1. Be precise.", Dsxir.LM.empty_usage()}
    end)

    ctx = %{
      kind: :given_attempts,
      decl: decl(),
      attempts: attempts(),
      n: 3,
      temperature: 1.2,
      lm: {Dsxir.LM.Sycophant, []}
    }

    assert {:ok, instrs} = GivenAttempts.run(ctx)
    assert length(instrs) == 3
    assert Enum.count(instrs, &(&1 == "Best so far.")) == 2
  end

  test "renders the attempts worst-first in the prompt" do
    expect(Dsxir.LM.Sycophant, :generate_text, fn _config, [%{content: prompt}], _opts ->
      worst = :binary.match(prompt, "Worst attempt.") |> elem(0)
      mediocre = :binary.match(prompt, "Mediocre attempt.") |> elem(0)
      best = :binary.match(prompt, "Best so far.") |> elem(0)

      assert worst < mediocre
      assert mediocre < best

      {:ok, "1. Be precise.", Dsxir.LM.empty_usage()}
    end)

    ctx = %{
      kind: :given_attempts,
      decl: decl(),
      attempts: attempts(),
      n: 2,
      temperature: 1.2,
      lm: {Dsxir.LM.Sycophant, []}
    }

    assert {:ok, _} = GivenAttempts.run(ctx)
  end

  test "passes the temperature through to the LM call" do
    expect(Dsxir.LM.Sycophant, :generate_text, fn _config, _msgs, opts ->
      assert Keyword.fetch!(opts, :temperature) == 1.2
      {:ok, "1. Be precise.", Dsxir.LM.empty_usage()}
    end)

    ctx = %{
      kind: :given_attempts,
      decl: decl(),
      attempts: attempts(),
      n: 2,
      temperature: 1.2,
      lm: {Dsxir.LM.Sycophant, []}
    }

    assert {:ok, _} = GivenAttempts.run(ctx)
  end

  test "surfaces LM errors" do
    expect(Dsxir.LM.Sycophant, :generate_text, fn _, _, _ ->
      {:error, %Dsxir.Errors.LM.RateLimited{}}
    end)

    ctx = %{
      kind: :given_attempts,
      decl: decl(),
      attempts: attempts(),
      n: 4,
      temperature: 1.2,
      lm: {Dsxir.LM.Sycophant, []}
    }

    assert {:error, %Dsxir.Errors.LM.RateLimited{}} = GivenAttempts.run(ctx)
  end
end
