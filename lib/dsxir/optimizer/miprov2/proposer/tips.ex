defmodule Dsxir.Optimizer.MIPROv2.Proposer.Tips do
  @moduledoc """
  Static lookup of proposer "tips" — short stylistic hints prepended to the
  grounded-proposer prompt to nudge instruction-generation style.

  Use `:persona`, `:creative`, `:simple`, `:concise`, a free-form binary, or
  `nil`. Unknown atoms resolve to `nil`.
  """

  @tips %{
    persona: "Use a clear persona (e.g., \"You are an expert...\") in the instruction.",
    creative: "Be creative and try an unconventional phrasing.",
    simple: "Keep the instruction as simple as possible — one sentence.",
    concise: "Keep the instruction under 20 words."
  }

  @type tip :: atom() | String.t() | nil

  @doc """
  Resolve a tip key to its prompt fragment. Returns the input string unchanged
  when given a binary, looks up known atoms in the static table, and returns
  `nil` for `nil` or unknown atoms.
  """
  @spec resolve(tip()) :: String.t() | nil
  def resolve(nil), do: nil
  def resolve(tip) when is_binary(tip), do: tip
  def resolve(tip) when is_atom(tip), do: Map.get(@tips, tip)
end
