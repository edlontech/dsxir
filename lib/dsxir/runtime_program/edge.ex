defmodule Dsxir.RuntimeProgram.Edge do
  @moduledoc """
  Typed data flow between a producer endpoint and a consumer endpoint inside a
  runtime program.

  `from:` is one of `{:program_input, atom()}`, `{:node, atom(), atom()}`, or
  `{:const, term()}`. `to:` is `{:node, atom(), atom()}` or
  `{:program_output, atom()}`. `kind:` is `:required` or `:optional`.
  """

  @enforce_keys [:from, :to]
  defstruct [:from, :to, kind: :required]

  @type from :: {:program_input, atom()} | {:node, atom(), atom()} | {:const, term()}
  @type to :: {:node, atom(), atom()} | {:program_output, atom()}
  @type kind :: :required | :optional

  @type t :: %__MODULE__{from: from(), to: to(), kind: kind()}
end
