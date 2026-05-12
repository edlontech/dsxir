defmodule Dsxir.CallContext do
  @moduledoc """
  Value type handed to `call_plugs`. Carries the call-site information a plug
  needs to make an `:ok | {:halt, reason}` decision before the predictor's
  `forward/4` runs.

  Plugs are plain functions of arity 1:

      plug_fn :: (%Dsxir.CallContext{} -> :ok | {:halt, reason :: term()})

  Plugs see the resolved metadata (`Dsxir.Settings.resolve(:metadata)` merged
  at the wrapper) so tenant identity, request id, and any custom keys are
  available without going back through settings.
  """

  @enforce_keys [:predictor, :signature, :inputs, :program]
  defstruct [:predictor, :signature, :inputs, :program, metadata: %{}, opts: []]

  @type t :: %__MODULE__{
          predictor: atom(),
          signature: module(),
          inputs: map(),
          program: Dsxir.Program.t(),
          metadata: map(),
          opts: keyword()
        }

  @doc """
  Build a `t()` from `fields`. Raises if any of the `:predictor`, `:signature`,
  `:inputs`, or `:program` keys are missing.
  """
  @spec new(keyword()) :: t()
  def new(fields) when is_list(fields) do
    struct!(__MODULE__, fields)
  end
end
