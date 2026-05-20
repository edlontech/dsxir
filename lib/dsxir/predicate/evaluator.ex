defmodule Dsxir.Predicate.Evaluator do
  @moduledoc """
  Pure-total predicate evaluator.

  Walks an AST against a runtime environment and returns
  `{:ok, boolean()}` or `{:error, %{code: :type_mismatch, ...}}` on
  shape mismatches that slipped past type-checking.
  """

  @type env :: %{atom() => map()}

  @doc """
  Evaluate a parsed predicate AST node against a runtime `env`.

  Returns `{:ok, boolean()}` on success, `{:error, map()}` on a runtime
  type mismatch (e.g. a field present at the wrong type).
  """
  @spec eval(term(), env()) :: {:ok, boolean()} | {:error, map()}
  def eval({:and, exprs}, env), do: eval_and(exprs, env)
  def eval({:or, exprs}, env), do: eval_or(exprs, env)

  def eval({:not, expr}, env) do
    case eval(expr, env) do
      {:ok, b} -> {:ok, not b}
      err -> err
    end
  end

  def eval({:lit, v}, _env) when is_boolean(v), do: {:ok, v}

  def eval({:lit, v}, _env),
    do: {:error, %{code: :type_mismatch, expected: :boolean, got: v}}

  def eval({op, lhs, rhs}, env) when op in [:eq, :neq, :lt, :lte, :gt, :gte] do
    with {:ok, l} <- resolve(lhs, env),
         {:ok, r} <- resolve(rhs, env) do
      compare(op, l, r)
    end
  end

  def eval({op, lhs, rhs}, env) when op in [:in, :not_in] do
    with {:ok, l} <- resolve(lhs, env),
         {:ok, list} <- resolve(rhs, env),
         :ok <- ensure_list(list) do
      case op do
        :in -> {:ok, Enum.member?(list, l)}
        :not_in -> {:ok, not Enum.member?(list, l)}
      end
    end
  end

  defp eval_and([], _env), do: {:ok, true}

  defp eval_and([expr | rest], env) do
    case eval(expr, env) do
      {:ok, true} -> eval_and(rest, env)
      {:ok, false} -> {:ok, false}
      err -> err
    end
  end

  defp eval_or([], _env), do: {:ok, false}

  defp eval_or([expr | rest], env) do
    case eval(expr, env) do
      {:ok, true} -> {:ok, true}
      {:ok, false} -> eval_or(rest, env)
      err -> err
    end
  end

  defp resolve({:lit, v}, _env), do: {:ok, v}
  defp resolve({:lit_list, vs}, _env), do: {:ok, vs}

  defp resolve({:field, ns, field}, env) do
    case env do
      %{^ns => %{^field => value}} -> {:ok, value}
      _ -> {:error, %{code: :type_mismatch, missing_field: {ns, field}}}
    end
  end

  defp resolve({:program_input, field}, env) do
    case env do
      %{program_input: %{^field => value}} -> {:ok, value}
      _ -> {:error, %{code: :type_mismatch, missing_field: {:program_input, field}}}
    end
  end

  defp resolve({:length, inner}, env) do
    with {:ok, value} <- resolve(inner, env) do
      cond do
        is_binary(value) -> {:ok, String.length(value)}
        is_list(value) -> {:ok, length(value)}
        true -> {:error, %{code: :type_mismatch, op: :length, got: value}}
      end
    end
  end

  defp compare(op, l, r) do
    if comparable?(l, r) do
      {:ok, apply_compare(op, l, r)}
    else
      {:error, %{code: :type_mismatch, op: op, lhs: l, rhs: r}}
    end
  end

  defp comparable?(l, r) when is_number(l) and is_number(r), do: true
  defp comparable?(l, r) when is_binary(l) and is_binary(r), do: true
  defp comparable?(l, r) when is_atom(l) and is_atom(r), do: true
  defp comparable?(l, r) when is_boolean(l) and is_boolean(r), do: true
  defp comparable?(nil, nil), do: true
  defp comparable?(_, _), do: false

  defp apply_compare(:eq, l, r), do: l == r
  defp apply_compare(:neq, l, r), do: l != r
  defp apply_compare(:lt, l, r), do: l < r
  defp apply_compare(:lte, l, r), do: l <= r
  defp apply_compare(:gt, l, r), do: l > r
  defp apply_compare(:gte, l, r), do: l >= r

  defp ensure_list(v) when is_list(v), do: :ok
  defp ensure_list(v), do: {:error, %{code: :type_mismatch, expected: :list, got: v}}
end
