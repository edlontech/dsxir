defmodule Dsxir.Stream.Event do
  @moduledoc """
  Unified streaming event surfaced to a `:stream` consumer of
  `Dsxir.Predictor.Predict`.

  Predict translates each `Dsxir.LM.StreamChunk` into one of these and, when
  `listen:` names output fields, injects `:field_delta` events carrying
  marker-stripped field content. A single sink therefore sees the whole stream;
  a UI answer-box filters to `:field_delta` for its field while a raw-output view
  consumes `:token`. The `:type` tag selects the payload:

    * `:token` — `data` is the raw text delta straight from the model (markers
      and all); the unfiltered firehose.
    * `:field_delta` — `data` is a fragment of a listened output field's value,
      markers stripped; `field` names the field. Only emitted for fields named in
      `listen:`.
    * `:reasoning` — `data` is a reasoning-text fragment.
    * `:tool_call` — `data` is `%{id, name, arguments_delta}`.
    * `:usage` — `data` is a `%Dsxir.Cost{}`.
    * `:done` — terminal success; `data` is the final accumulator (often `nil`).
    * `:error` — terminal failure; `data` is a `Dsxir.Errors.LM.*`.

  `field` is `nil` for every type except `:field_delta`.
  """

  @enforce_keys [:type]
  defstruct [:type, :data, :field]

  @type type :: :token | :field_delta | :reasoning | :tool_call | :usage | :done | :error

  @type t :: %__MODULE__{
          type: type(),
          data: term(),
          field: atom() | nil
        }

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%Dsxir.Stream.Event{} = event, opts) do
      fields =
        Enum.reject([type: event.type, field: event.field, data: event.data], fn {_, v} ->
          is_nil(v)
        end)

      concat(["#Dsxir.Stream.Event<", to_doc(Map.new(fields), opts), ">"])
    end
  end
end
