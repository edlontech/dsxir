defmodule Dsxir.Predictor.ProgramOfThought do
  @moduledoc """
  Solves a task by generating Elixir code, executing it in the Dune sandbox,
  regenerating on failure up to `:max_iters` (default 3), then LM-extracting
  the signature's typed outputs from the successful run's result.

  ## Declaration

      predictor :solve, Dsxir.Predictor.ProgramOfThought,
        signature: MathWordProblem

  `:max_iters` and the sandbox opts below are passed at call time, not in the
  declaration:

      call(prog, :solve, inputs, max_iters: 3)

  ## Recognised opts

    * `:max_iters` (default 3) - total code attempts before raising.
    * `:exec_timeout` (default 5_000 ms), `:max_heap_size`, `:max_reductions`,
      `:atom_pool_size`, `:allowlist` - forwarded to the Dune sandbox.
    * `:trace_name` (default `:program_of_thought`) - keep distinct from any
      declared predictor name (see `Dsxir.Predictor.ReAct` for the footgun).

  The returned `%Dsxir.Prediction{}` carries the signature's real outputs plus
  `:generated_code` and `:trajectory`. Exhausting `:max_iters` without a
  successful run raises `Dsxir.Errors.Framework.CodeExecutionError`.
  """

  @behaviour Dsxir.Predictor

  alias Dsxir.Predictor.CodeExec.Engine

  @default_max_iters 3

  @impl Dsxir.Predictor
  def forward(%Dsxir.Program.State{} = state, signature, inputs, opts) do
    engine_opts =
      opts
      |> Keyword.put_new(:max_iters, @default_max_iters)
      |> Keyword.put(:exec_type, :program_of_thought)
      |> Keyword.put_new(:trace_name, :program_of_thought)

    Engine.run(state, signature, inputs, engine_opts)
  end

  @impl Dsxir.Predictor
  def augmented_outputs(_signature), do: [:generated_code, :trajectory]
end
