defmodule Dsxir.Errors.Halted do
  @moduledoc "Halted-class errors: explicit policy stops surfaced through call_plugs and friends."
  use Splode.ErrorClass, class: :halted
end

defmodule Dsxir.Errors.Halted.Plug do
  @moduledoc false
  use Splode.Error, fields: [:plug, :reason, :context], class: :halted
  def message(struct), do: inspect(struct)
end
