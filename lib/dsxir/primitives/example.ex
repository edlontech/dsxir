defmodule Dsxir.Example do
  @moduledoc """
  A labeled example used as input to optimizers and to the demo channel.

  Carries an `inputs` map and a `labels` map. The `input_keys` set determines
  which keys in the unified `data` view are inputs; the rest are labels.
  """

  @enforce_keys [:data]
  defstruct [:data, input_keys: MapSet.new()]

  @type t :: %__MODULE__{
          data: map(),
          input_keys: MapSet.t()
        }

  @doc """
  Build an example from `data`. Pass `:input_keys` in `opts` to mark which keys
  are inputs; everything else is treated as a label.
  """
  @spec new(map(), keyword()) :: t()
  def new(data, opts \\ []) when is_map(data) and is_list(opts) do
    %__MODULE__{
      data: data,
      input_keys: opts |> Keyword.get(:input_keys, []) |> MapSet.new()
    }
  end

  @doc "Replace the example's input-key set with `keys`."
  @spec with_inputs(t(), [atom()]) :: t()
  def with_inputs(%__MODULE__{} = example, keys) when is_list(keys) do
    %{example | input_keys: MapSet.new(keys)}
  end

  @doc "Project `data` down to the input fields only."
  @spec inputs(t()) :: map()
  def inputs(%__MODULE__{data: data, input_keys: keys}) do
    Map.take(data, MapSet.to_list(keys))
  end

  @doc "Project `data` down to the label fields (the complement of the inputs)."
  @spec labels(t()) :: map()
  def labels(%__MODULE__{data: data, input_keys: keys}) do
    Map.drop(data, MapSet.to_list(keys))
  end
end
