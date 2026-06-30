defmodule Dsxir.LM.StreamChunk do
  @moduledoc """
  Provider-neutral streaming event emitted by a `Dsxir.LM` implementation when a
  `:stream` callback is passed to `generate_text/3`.

  Implementations translate their provider SDK's chunk type into this struct so
  consumers never depend on a specific provider (the same boundary `Dsxir.Cost`
  and `Dsxir.Errors.LM.*` draw for usage and errors). The `:type` tag selects
  what `:data` carries:

    * `:text_delta` — `data` is a `String.t()` fragment of generated text.
    * `:reasoning_delta` — `data` is a `String.t()` fragment of reasoning text.
    * `:tool_call_delta` — `data` is `%{id: String.t(), name: String.t() | nil,
      arguments_delta: String.t()}`.
    * `:usage` — `data` is a `%Dsxir.Cost{}` with final token counts.
    * `:done` — terminal success; `data` is the final accumulator (often `nil`).
    * `:failed` / `:incomplete` / `:cancelled` — terminal failure; `data` is a
      `Dsxir.Errors.LM.*` describing why the stream halted.

  `index` disambiguates parallel tool calls or multiple choices when the provider
  supplies it; it is `nil` otherwise.
  """

  @enforce_keys [:type]
  defstruct [:type, :data, :index]

  @type type ::
          :text_delta
          | :reasoning_delta
          | :tool_call_delta
          | :usage
          | :done
          | :failed
          | :incomplete
          | :cancelled

  @type t :: %__MODULE__{
          type: type(),
          data: term(),
          index: non_neg_integer() | nil
        }

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%Dsxir.LM.StreamChunk{} = chunk, opts) do
      fields =
        Enum.reject([type: chunk.type, data: chunk.data, index: chunk.index], fn {_, v} ->
          is_nil(v)
        end)

      concat(["#Dsxir.LM.StreamChunk<", to_doc(Map.new(fields), opts), ">"])
    end
  end
end
