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

  defdelegate evaluate(ev, program), to: Dsxir.Evaluate, as: :run
  defdelegate evaluate!(ev, program), to: Dsxir.Evaluate, as: :run!

  defdelegate compile(impl, student, trainset, metric, opts), to: Dsxir.Optimizer

  defdelegate save(program, path), to: Dsxir.Artifact
  defdelegate save!(program, path), to: Dsxir.Artifact
  defdelegate load(target_module, path, opts \\ []), to: Dsxir.Artifact
  defdelegate load!(target_module, path, opts \\ []), to: Dsxir.Artifact
end
