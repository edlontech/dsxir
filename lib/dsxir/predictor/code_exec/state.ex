defmodule Dsxir.Predictor.CodeExec.State do
  @moduledoc """
  Accumulator for the `Dsxir.Predictor.CodeExec.Engine` `reduce_while` loop.
  Pure data. `trajectory` grows newest-last; each entry is one `(code, outcome)`
  attempt.
  """

  defstruct trajectory: [], iter: 0, code: nil, result: nil, done?: false

  @type entry :: %{code: String.t(), error: String.t() | nil, type: atom() | nil, ok?: boolean()}
  @type result :: %{value: term(), inspected: String.t(), stdio: String.t()}
  @type t :: %__MODULE__{
          trajectory: [entry()],
          iter: non_neg_integer(),
          code: String.t() | nil,
          result: result() | nil,
          done?: boolean()
        }

  @doc "Appends a failed attempt to the trajectory and bumps `iter`."
  @spec push_failure(t(), String.t(), String.t(), atom()) :: t()
  def push_failure(%__MODULE__{} = state, code, error, type) do
    entry = %{code: code, error: error, type: type, ok?: false}
    %{state | trajectory: state.trajectory ++ [entry], code: code, iter: state.iter + 1}
  end

  @doc "Records a successful run: appends the entry, stores the result, sets `done?`."
  @spec mark_success(t(), String.t(), result()) :: t()
  def mark_success(%__MODULE__{} = state, code, result) do
    entry = %{code: code, error: nil, type: nil, ok?: true}

    %{
      state
      | trajectory: state.trajectory ++ [entry],
        code: code,
        result: result,
        done?: true
    }
  end

  @doc "The most recent failed attempt, or `nil` if none have failed."
  @spec last_failure(t()) :: entry() | nil
  def last_failure(%__MODULE__{trajectory: traj}) do
    traj |> Enum.filter(&(not &1.ok?)) |> List.last()
  end

  @doc """
  The Dune failure type to stamp on `CodeExecutionError` when the loop is
  exhausted: the shared type when every failure had the same type, else
  `:max_iters`.
  """
  @spec last_type(t()) :: atom()
  def last_type(%__MODULE__{trajectory: traj}) do
    case traj |> Enum.reject(& &1.ok?) |> Enum.map(& &1.type) |> Enum.uniq() do
      [type] -> type
      _ -> :max_iters
    end
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%Dsxir.Predictor.CodeExec.State{} = state, _opts) do
      concat([
        "#Dsxir.Predictor.CodeExec.State<iter: ",
        Integer.to_string(state.iter),
        ", done?: ",
        Atom.to_string(state.done?),
        ", trajectory: ",
        Integer.to_string(length(state.trajectory)),
        " attempt(s)>"
      ])
    end
  end
end
