defmodule Dsxir.Optimizer.COPRO.Proposer do
  @moduledoc """
  Instruction proposer for `Dsxir.Optimizer.COPRO`. Dispatches to `Basic`
  (round 0, from the current instruction) or `GivenAttempts` (later rounds,
  from the sorted attempt history). Both return exactly `n` instructions.
  """

  alias Dsxir.Optimizer.COPRO.Proposer.Basic
  alias Dsxir.Optimizer.COPRO.Proposer.GivenAttempts

  @type ctx :: map()

  @spec propose(ctx()) :: {:ok, [String.t()]} | {:error, Exception.t()}
  def propose(%{kind: :basic} = ctx), do: Basic.run(ctx)
  def propose(%{kind: :given_attempts} = ctx), do: GivenAttempts.run(ctx)

  @doc "Parse an LM completion into a list of instruction strings."
  @spec parse(String.t()) :: [String.t()]
  def parse(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.map(&strip_line/1)
    |> Enum.reject(&(&1 == ""))
  end

  @doc """
  Render a signature's field list as a `name (type)` block, one field per line.
  Used by both proposers to ground the prompt in the predictor's shape.
  """
  @spec render_fields([Dsxir.Signature.Field.t()]) :: String.t()
  def render_fields(fields) do
    Enum.map_join(fields, "\n", fn f -> "- #{f.name} (#{inspect(f.type)})" end)
  end

  @doc """
  Truncate `list` to `n` items, or repeat `fallback` until the result has
  exactly `n` items.
  """
  @spec pad([String.t()], pos_integer(), String.t()) :: [String.t()]
  def pad(list, n, fallback) when is_list(list) and is_integer(n) and n > 0 do
    take = Enum.take(list, n)
    take ++ List.duplicate(fallback, max(0, n - length(take)))
  end

  defp strip_line(line) do
    line
    |> String.trim()
    |> String.replace(~r/^\s*\d+[\.\)]\s*/, "")
    |> String.replace(~r/^(Instruction|Prefix)\s*[:#]\s*/i, "")
    |> String.trim()
    |> String.trim("\"")
    |> String.trim()
  end
end
