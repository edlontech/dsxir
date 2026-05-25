defmodule Dsxir.Predictor.CodeExec.ToolAllowlist do
  @moduledoc """
  Extends `Dune.Allowlist.Default` with exactly one additional permitted
  function: the CodeAct tool dispatcher. Generated code may call user tools
  only through `Dsxir.Predictor.CodeExec.ToolBridge.call/3`; everything else
  remains under the default safe allowlist.
  """
  use Dune.Allowlist, extend: Dune.Allowlist.Default

  allow(Dsxir.Predictor.CodeExec.ToolBridge, only: [:call])
end
