defmodule Dsxir.Adapter.Chat.StreamParser do
  @moduledoc """
  Incremental parser for the Chat adapter's `[[ ## field ## ]]` marker protocol,
  used to stream individual output fields as their text arrives.

  `push/2` feeds a raw text delta and returns `{events, parser}` where each event
  is a `%Dsxir.Stream.Event{type: :field_delta, field: name, data: fragment}` for
  a *listened* field, with marker-edge whitespace stripped (matching the batch
  parser's `String.trim/1`, so the concatenated stream equals the parsed value).
  Text that could still grow into a marker — or trailing whitespace that might be
  the gap before one — is held back until the next delta disambiguates it.
  `finish/1` flushes the final field, which has no closing marker.

  Pure and process-free: the struct is threaded as the accumulator of a streaming
  callback, so no process is needed to carry state across deltas.
  """

  alias Dsxir.Stream.Event

  @marker ~r/\[\[\s*##\s*(?<name>[a-zA-Z0-9_]+)\s*##\s*\]\]/

  # Matches, anchored at end of string, an optional whitespace gap followed by an
  # optional prefix of a marker (`[`, `[[`, `[[ ##`, `[[ ## name`, ...). The match
  # start is the byte after which everything must be withheld until more text
  # arrives. Greedy + `$`-anchored, so `Regex.run` returns the longest such tail.
  @holdback ~r/\s*(\[(\[(\s*(\#(\#(\s*(\w*(\s*(\#(\#(\s*(\](\])?)?)?)?)?)?)?)?)?)?)?)?)?$/

  @enforce_keys [:listened]
  defstruct buffer: "", current_field: nil, at_field_start: false, listened: nil

  @type t :: %__MODULE__{
          buffer: String.t(),
          current_field: atom() | nil,
          at_field_start: boolean(),
          listened: MapSet.t(atom())
        }

  @doc "Build a parser that emits `:field_delta` events for `listened_fields`."
  @spec new([atom()]) :: t()
  def new(listened_fields) when is_list(listened_fields) do
    %__MODULE__{listened: MapSet.new(listened_fields)}
  end

  @doc """
  Feed a raw text delta, returning `{events, parser}`. Emitted events are
  marker-stripped `:field_delta` fragments for listened fields; text that could
  still grow into a marker is withheld in the returned parser.
  """
  @spec push(t(), String.t()) :: {[Event.t()], t()}
  def push(%__MODULE__{} = parser, text) when is_binary(text) do
    process(%{parser | buffer: parser.buffer <> text}, [])
  end

  @doc "Flush the final field's withheld buffer (it has no closing marker)."
  @spec finish(t()) :: {[Event.t()], t()}
  def finish(%__MODULE__{} = parser) do
    {events, parser} = emit_region(parser, parser.buffer, trailing: true)
    {events, %{parser | buffer: ""}}
  end

  defp process(parser, acc) do
    case Regex.run(@marker, parser.buffer, return: :index) do
      [{m_start, m_len}, {n_start, n_len}] ->
        before = binary_part(parser.buffer, 0, m_start)
        {events, parser} = emit_region(parser, before, trailing: true)
        name = parser.buffer |> binary_part(n_start, n_len) |> field_atom(parser.listened)
        rest_start = m_start + m_len
        rest = binary_part(parser.buffer, rest_start, byte_size(parser.buffer) - rest_start)

        process(
          %{parser | buffer: rest, current_field: name, at_field_start: true},
          acc ++ events
        )

      nil ->
        {emit, hold} = split_holdback(parser.buffer)
        {events, parser} = emit_region(parser, emit, trailing: false)
        {acc ++ events, %{parser | buffer: hold}}
    end
  end

  defp split_holdback(buffer) do
    [{start, _} | _] = Regex.run(@holdback, buffer, return: :index)
    {binary_part(buffer, 0, start), binary_part(buffer, start, byte_size(buffer) - start)}
  end

  defp emit_region(parser, "", _opts), do: {[], parser}

  defp emit_region(%{listened: listened, current_field: field} = parser, text, opts) do
    if MapSet.member?(listened, field) do
      stripped =
        text
        |> maybe_trim_leading(parser.at_field_start)
        |> maybe_trim_trailing(Keyword.get(opts, :trailing, false))

      case stripped do
        "" ->
          {[], parser}

        value ->
          {[%Event{type: :field_delta, field: field, data: value}],
           %{parser | at_field_start: false}}
      end
    else
      {[], parser}
    end
  end

  defp maybe_trim_leading(text, true), do: String.trim_leading(text)
  defp maybe_trim_leading(text, false), do: text

  defp maybe_trim_trailing(text, true), do: String.trim_trailing(text)
  defp maybe_trim_trailing(text, false), do: text

  # A field name appearing in the stream maps to its listened atom, or to a
  # sentinel for any declared-but-not-listened or unknown field, so the region is
  # tracked (and suppressed) without creating atoms from arbitrary stream text.
  defp field_atom(name, listened) do
    atom = String.to_existing_atom(name)
    if MapSet.member?(listened, atom), do: atom, else: :__unlistened__
  rescue
    ArgumentError -> :__unlistened__
  end
end
