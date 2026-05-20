defmodule Dsxir.ProgramContext do
  @moduledoc """
  Value type handed to `program_plugs` at runtime-program construction time.

  Plugs resolved from `Dsxir.Settings.resolve(:program_plugs, [])` see this
  struct and must return `:ok` to continue or `{:halt, reason}` to abort
  construction with `Dsxir.Errors.Halted.ProgramPlug`.
  """

  @enforce_keys [:runtime_program]
  defstruct [:runtime_program, metadata: %{}, caller: nil]

  @type t :: %__MODULE__{
          runtime_program: Dsxir.RuntimeProgram.t(),
          metadata: map(),
          caller: term()
        }

  @doc """
  Build a context for `rp`. The `:metadata` opt overrides the value resolved
  from `Dsxir.Settings.resolve(:metadata, %{})`; the `:caller` opt is free-form
  and defaults to `nil`.
  """
  @spec new(Dsxir.RuntimeProgram.t(), keyword()) :: t()
  def new(%Dsxir.RuntimeProgram{} = rp, opts \\ []) when is_list(opts) do
    %__MODULE__{
      runtime_program: rp,
      metadata: Keyword.get(opts, :metadata, Dsxir.Settings.resolve(:metadata, %{})),
      caller: Keyword.get(opts, :caller)
    }
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%Dsxir.ProgramContext{runtime_program: rp, caller: caller}, _opts) do
      concat([
        "#Dsxir.ProgramContext<id: ",
        inspect(rp.id),
        ", version: ",
        Dsxir.RuntimeProgram.short_version(rp.version),
        ", caller: ",
        inspect(caller),
        ">"
      ])
    end
  end
end
