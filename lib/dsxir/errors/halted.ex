defmodule Dsxir.Errors.Halted do
  @moduledoc "Halted-class errors: explicit policy stops surfaced through call_plugs and friends."
  use Splode.ErrorClass, class: :halted
end

defmodule Dsxir.Errors.Halted.Plug do
  @moduledoc "Raised when a function in `Dsxir.Settings.call_plugs` returns `{:halt, reason}` before predictor dispatch."
  use Splode.Error, fields: [:plug, :reason, :context], class: :halted

  def message(%{plug: plug, reason: reason, context: %Dsxir.CallContext{predictor: pred}}) do
    "halted by plug #{inspect(plug)} at predictor #{inspect(pred)}: reason=#{inspect(reason)}"
  end

  def message(%{plug: plug, reason: reason}) do
    "halted by plug #{inspect(plug)}: reason=#{inspect(reason)}"
  end
end

defmodule Dsxir.Errors.Halted.ProgramPlug do
  @moduledoc "Raised when a function in `program_plugs` returns `{:halt, reason}` at runtime-program construction."
  use Splode.Error, fields: [:plug, :reason, :context], class: :halted

  def message(%{plug: plug, reason: reason, context: %Dsxir.ProgramContext{runtime_program: rp}}) do
    "halted by program_plug #{inspect(plug)} for program #{rp.id}: reason=#{inspect(reason)}"
  end

  def message(%{plug: plug, reason: reason}) do
    "halted by program_plug #{inspect(plug)}: reason=#{inspect(reason)}"
  end
end
