defmodule Dsxir do
  @moduledoc """
  Top-level facade for the dsxir framework. Re-exports the settings entry points;
  predictors, adapters, optimizers, and LM impls are reached for under their own
  module names.

  Public surface relevant to a user program:

      use Dsxir.Signature
      use Dsxir.Module

      Dsxir.configure/1
      Dsxir.context/2

      Dsxir.Predictor.Predict
      Dsxir.Adapter.Chat
      Dsxir.LM.Sycophant
  """

  defdelegate configure(opts), to: Dsxir.Settings
  defdelegate context(frame, fun), to: Dsxir.Settings
end
