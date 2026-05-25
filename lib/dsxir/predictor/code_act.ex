defmodule Dsxir.Predictor.CodeAct do
  @moduledoc """
  ProgramOfThought whose generated code may call user-provided `Dsxir.Tool`s
  from inside the Dune sandbox. The generated Elixir is constrained to the
  default safe allowlist plus one dispatcher function; the tools themselves are
  trusted and run with their own privileges, exactly as `Dsxir.Predictor.ReAct`
  trusts its tools.

  ## Declaration

      predictor :solve, Dsxir.Predictor.CodeAct,
        signature: DataTask

  `:tools`, `:max_iters`, and the sandbox opts are passed at call time, not in
  the declaration (tools are usually runtime values):

      call(prog, :solve, inputs, tools: [stats_tool, parse_tool], max_iters: 5)

  ## Recognised opts

    * `:tools` (default `[]`) - `Dsxir.Tool` structs callable from the code.
      With no tools, behaves like `Dsxir.Predictor.ProgramOfThought`.
    * `:max_iters` (default 5), plus the sandbox opts and `:trace_name`
      documented on `Dsxir.Predictor.ProgramOfThought`.

  If a caller passes a custom `:allowlist`, it must permit
  `Dsxir.Predictor.CodeExec.ToolBridge.call/3` or tool calls from generated
  code will be rejected by the sandbox.

  Returns a `%Dsxir.Prediction{}` with the signature's outputs plus
  `:generated_code` and `:trajectory`.
  """

  @behaviour Dsxir.Predictor

  alias Dsxir.Predictor.CodeExec.Engine

  @default_max_iters 5

  @impl Dsxir.Predictor
  def forward(%Dsxir.Program.State{} = state, signature, inputs, opts) do
    engine_opts =
      opts
      |> Keyword.put_new(:max_iters, @default_max_iters)
      |> Keyword.put_new(:tools, [])
      |> Keyword.put(:exec_type, :code_act)
      |> Keyword.put_new(:trace_name, :code_act)

    Engine.run(state, signature, inputs, engine_opts)
  end

  @impl Dsxir.Predictor
  def augmented_outputs(_signature), do: [:generated_code, :trajectory]
end
