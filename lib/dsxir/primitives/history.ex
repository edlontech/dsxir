defmodule Dsxir.Primitives.History do
  @moduledoc """
  Multi-turn conversation value type. Bind one to a signature input field whose
  Zoi type is `Dsxir.Primitives.History`; the chat adapter materializes the
  conversation into the prompt sequence.

  Distinct from `Dsxir.History` (the `inspect_history` developer tool). The
  name overlap mirrors DSPy's `dspy.History` (the value type) and
  `dspy.inspect_history` (the debug helper).

  Entries are plain maps to keep the struct cheap and serializable:

      %Dsxir.Primitives.History{
        messages: [
          %{role: :user, content: "What is the capital of France?"},
          %{role: :assistant, content: "Paris."}
        ]
      }
  """

  defstruct messages: []

  @type role :: :system | :user | :assistant
  @type message :: %{role: role(), content: String.t()}
  @type t :: %__MODULE__{messages: [message()]}

  @spec new([message()]) :: t()
  def new(messages \\ []) when is_list(messages), do: %__MODULE__{messages: messages}

  @spec push(t(), role(), String.t()) :: t()
  def push(%__MODULE__{messages: msgs} = h, role, content)
      when role in [:system, :user, :assistant] and is_binary(content) do
    %{h | messages: msgs ++ [%{role: role, content: content}]}
  end

  @doc "Materialize as a list of `%Sycophant.Message{}` for adapter consumption."
  @spec to_messages(t()) :: [Sycophant.Message.t()]
  def to_messages(%__MODULE__{messages: msgs}) do
    Enum.map(msgs, fn %{role: role, content: content} ->
      case role do
        :system -> Sycophant.Message.system(content)
        :user -> Sycophant.Message.user(content)
        :assistant -> Sycophant.Message.assistant(content)
      end
    end)
  end
end
