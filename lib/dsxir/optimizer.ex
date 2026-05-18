defmodule Dsxir.Optimizer do
  @moduledoc """
  Behaviour and dispatcher for program optimizers.

  An optimizer compiles a `Dsxir.Program.t()` against a trainset under a
  `Dsxir.Metric.t()`, returning a new program plus an open `stats` map.

  Implementations declare `@behaviour Dsxir.Optimizer` and implement
  `compile/4`. Callers invoke an optimizer through `compile/5`, which performs
  argument validation and delegates to the impl module.

  The return contract is fixed across versions:

      {:ok, Dsxir.Program.t(), stats :: map()} | {:error, Exception.t()}

  `stats` is an open map. Each optimizer documents the keys it populates;
  consumers must tolerate unknown keys.
  """

  alias Dsxir.Program

  @type stats :: map()
  @type result :: {:ok, Program.t(), stats()} | {:error, Exception.t()}

  @callback compile(
              student :: Program.t(),
              trainset :: [Dsxir.Example.t()],
              metric :: nil | Dsxir.Metric.t(),
              opts :: keyword()
            ) :: result()

  @doc """
  Dispatch to `impl.compile/4` with validated arguments.

  Guards: `impl` must be an atom (module), `trainset` a list, `metric` must be
  either `nil` or a 3-arity function (optimizers that do not need a metric —
  e.g. `Dsxir.Optimizer.KNNFewShot` — accept `nil`), and `opts` a keyword list
  (any list satisfies the guard; impls are expected to treat it as a keyword
  list).
  """
  @spec compile(
          module(),
          Program.t(),
          [Dsxir.Example.t()],
          nil | Dsxir.Metric.t(),
          keyword()
        ) :: result()
  def compile(impl, %Program{} = student, trainset, nil, opts)
      when is_atom(impl) and is_list(trainset) and is_list(opts) do
    impl.compile(student, trainset, nil, opts)
  end

  def compile(impl, %Program{} = student, trainset, metric, opts)
      when is_atom(impl) and is_list(trainset) and is_function(metric, 3) and is_list(opts) do
    impl.compile(student, trainset, metric, opts)
  end
end
