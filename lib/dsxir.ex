defmodule Dsxir do
  @moduledoc """
  Top-level facade for the dsxir framework. Re-exports the user-facing entry
  points; predictors, adapters, optimizers, and LM impls are reached for under
  their own module names.

  Public surface relevant to a user program:

      use Dsxir.Signature
      use Dsxir.Module

      Dsxir.configure/1
      Dsxir.context/2
      Dsxir.with_trace/1

      Dsxir.evaluate/2
      Dsxir.evaluate!/2
      Dsxir.compile/5
      Dsxir.save/2
      Dsxir.save!/2
      Dsxir.load/2
      Dsxir.load/3
      Dsxir.load!/2
      Dsxir.load!/3

      Dsxir.Predictor.Predict
      Dsxir.Adapter.Chat
      Dsxir.LM.Sycophant
  """

  defdelegate configure(opts), to: Dsxir.Settings
  defdelegate context(frame, fun), to: Dsxir.Settings

  @doc """
  Run `fun.()` with a per-process trace accumulator open. The block must return
  `{program, prediction}` (the standard `forward/2` shape). The helper returns
  `{program, prediction, trace}` where `trace` is the list of recorded entries
  in invocation order.

  The accumulator is process-local. Inside the block, any `Dsxir.Module.call/3`
  running in the calling process records an entry; calls inside spawned tasks
  (`Dsxir.Predictor.Parallel`, user-supplied `Task`s) do not — Trace does not
  cross process boundaries in v0.

  When `fun.()` raises, throws, or exits, the prior accumulator is restored in
  the matching `rescue` / `catch` clause and the original condition is
  reraised. Partial traces on failure are not surfaced.
  """
  @spec with_trace((-> {Dsxir.Program.t(), Dsxir.Prediction.t()})) ::
          {Dsxir.Program.t(), Dsxir.Prediction.t(), [Dsxir.Trace.entry()]}
  def with_trace(fun) when is_function(fun, 0) do
    prior = Dsxir.Trace.start()

    try do
      {program, prediction} = fun.()
      {program, prediction, Dsxir.Trace.stop(prior)}
    rescue
      e ->
        _ = Dsxir.Trace.stop(prior)
        reraise e, __STACKTRACE__
    catch
      kind, reason ->
        _ = Dsxir.Trace.stop(prior)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defdelegate evaluate(ev, program), to: Dsxir.Evaluate, as: :run
  defdelegate evaluate!(ev, program), to: Dsxir.Evaluate, as: :run!

  defdelegate compile(impl, student, trainset, metric, opts), to: Dsxir.Optimizer

  defdelegate save(program, path), to: Dsxir.Artifact
  defdelegate save!(program, path), to: Dsxir.Artifact
  defdelegate load(target_module, path, opts \\ []), to: Dsxir.Artifact
  defdelegate load!(target_module, path, opts \\ []), to: Dsxir.Artifact
end
