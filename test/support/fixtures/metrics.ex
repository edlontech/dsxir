defmodule Dsxir.Test.Fixtures.Metrics do
  @moduledoc """
  Shared metric helpers for fixture programs.
  """

  @doc """
  Case- and whitespace-insensitive exact match between the example's `:answer`
  label and the prediction's `:answer` field. Anything that does not match the
  expected shape scores `false`.
  """
  @spec exact_match(Dsxir.Example.t(), Dsxir.Prediction.t(), nil | list()) :: boolean()
  def exact_match(
        %Dsxir.Example{data: %{answer: expected}},
        %Dsxir.Prediction{fields: %{answer: actual}},
        _trace
      )
      when is_binary(expected) and is_binary(actual) do
    normalize(actual) == normalize(expected)
  end

  def exact_match(_, _, _), do: false

  defp normalize(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[[:punct:]]/u, "")
    |> String.replace(~r/\s+/, " ")
  end
end
