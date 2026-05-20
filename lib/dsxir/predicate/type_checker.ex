defmodule Dsxir.Predicate.TypeChecker do
  @moduledoc """
  Walks a predicate AST against a per-namespace field-type environment.

  Root expression must type-check to `:boolean`.
  """

  alias Dsxir.Predicate.AST

  @type type :: AST.type() | {:list, type()}
  @type env :: %{atom() => %{atom() => type()}}

  @doc """
  Type-check a parsed predicate expression against an `env`.

  Returns `:ok` when the root expression is `:boolean`, otherwise
  `{:error, map()}` with `:code, :expected, :got` (and optionally
  `:unknown, :what`) details.
  """
  @spec check(AST.t_expr(), env()) :: :ok | {:error, map()}
  def check(expr, env) do
    case infer(expr, env) do
      {:ok, :boolean} ->
        :ok

      {:ok, other} ->
        {:error, %{code: :predicate_type_error, expected: :boolean, got: other}}

      {:error, _} = e ->
        e
    end
  end

  # ---- inference --------------------------------------------------------

  defp infer({:and, exprs}, env), do: bool_branches(exprs, env)
  defp infer({:or, exprs}, env), do: bool_branches(exprs, env)

  defp infer({:not, expr}, env) do
    case infer(expr, env) do
      {:ok, :boolean} ->
        {:ok, :boolean}

      {:ok, other} ->
        {:error, %{code: :predicate_type_error, expected: :boolean, got: other}}

      err ->
        err
    end
  end

  defp infer({op, lhs, rhs}, env) when op in [:eq, :neq, :lt, :lte, :gt, :gte] do
    with {:ok, lt} <- infer(lhs, env),
         {:ok, rt} <- infer(rhs, env),
         :ok <- compat(lt, rt) do
      {:ok, :boolean}
    end
  end

  defp infer({op, lhs, {:lit_list, values}}, env) when op in [:in, :not_in] do
    with {:ok, lt} <- infer(lhs, env),
         :ok <- all_compat(lt, values) do
      {:ok, :boolean}
    end
  end

  defp infer({:in, _lhs, _rhs}, _env),
    do: {:error, %{code: :predicate_type_error, message: "in requires a list literal"}}

  defp infer({:not_in, _lhs, _rhs}, _env),
    do: {:error, %{code: :predicate_type_error, message: "not in requires a list literal"}}

  defp infer({:lit, v}, _env), do: {:ok, type_of(v)}

  defp infer({:length, inner}, env) do
    case infer(inner, env) do
      {:ok, :string} ->
        {:ok, :integer}

      {:ok, {:list, _}} ->
        {:ok, :integer}

      {:ok, other} ->
        {:error,
         %{code: :predicate_type_error, expected: {:one_of, [:string, :list]}, got: other}}

      err ->
        err
    end
  end

  defp infer({:field, ns, field}, env) do
    with {:ok, fields} <- env |> Map.fetch(ns) |> wrap_unknown(:field, {ns, field}) do
      fields
      |> Map.fetch(field)
      |> wrap_unknown(:field, {ns, field})
    end
  end

  defp infer({:program_input, field}, env) do
    with {:ok, fields} <-
           env |> Map.fetch(:program_input) |> wrap_unknown(:program_input, field) do
      fields
      |> Map.fetch(field)
      |> wrap_unknown(:program_input, field)
    end
  end

  defp wrap_unknown({:ok, _} = ok, _kind, _what), do: ok

  defp wrap_unknown(:error, kind, what),
    do: {:error, %{code: :predicate_type_error, unknown: kind, what: what}}

  defp bool_branches(exprs, env) do
    Enum.reduce_while(exprs, {:ok, :boolean}, fn expr, acc ->
      case infer(expr, env) do
        {:ok, :boolean} ->
          {:cont, acc}

        {:ok, other} ->
          {:halt, {:error, %{code: :predicate_type_error, expected: :boolean, got: other}}}

        {:error, _} = e ->
          {:halt, e}
      end
    end)
  end

  defp compat(a, b) when a == b, do: :ok
  defp compat(:any, _), do: :ok
  defp compat(_, :any), do: :ok
  defp compat(:integer, :float), do: :ok
  defp compat(:float, :integer), do: :ok

  defp compat(a, b),
    do: {:error, %{code: :predicate_type_error, expected: a, got: b}}

  defp all_compat(lhs_type, values) do
    case Enum.find(values, fn v -> compat(lhs_type, type_of(v)) != :ok end) do
      nil ->
        :ok

      bad ->
        {:error, %{code: :predicate_type_error, expected: lhs_type, got: type_of(bad)}}
    end
  end

  defp type_of(v) when is_boolean(v), do: :boolean
  defp type_of(v) when is_integer(v), do: :integer
  defp type_of(v) when is_float(v), do: :float
  defp type_of(v) when is_binary(v), do: :string
  defp type_of(v) when is_atom(v), do: :atom
  defp type_of(_), do: :any
end
