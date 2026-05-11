defmodule Dsxir.Prediction do
  @moduledoc """
  Typed output of a predictor call.

  `fields` is the validated, Zoi-passed output map keyed by output field name.
  Access protocol forwards directly to `fields`, so `pred[:answer]` and
  `pred.fields.answer` are equivalent.
  """

  @behaviour Access

  defstruct fields: %{}, completions: [], lm_usage: nil

  @type t :: %__MODULE__{
          fields: map(),
          completions: [String.t()],
          lm_usage: nil | map()
        }

  @spec new(map(), keyword()) :: t()
  def new(fields, opts \\ []) when is_map(fields) and is_list(opts) do
    %__MODULE__{
      fields: fields,
      completions: Keyword.get(opts, :completions, []),
      lm_usage: Keyword.get(opts, :lm_usage)
    }
  end

  @impl Access
  def fetch(%__MODULE__{fields: fields}, key), do: Map.fetch(fields, key)

  @impl Access
  def get_and_update(%__MODULE__{fields: fields} = pred, key, fun) do
    {value, updated} = Map.get_and_update(fields, key, fun)
    {value, %{pred | fields: updated}}
  end

  @impl Access
  def pop(%__MODULE__{fields: fields} = pred, key) do
    {value, updated} = Map.pop(fields, key)
    {value, %{pred | fields: updated}}
  end
end
