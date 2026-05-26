defmodule Dsxir.Predictor.MultiChainComparison do
  @moduledoc """
  Compares M pre-generated reasoning chains for a signature and integrates a
  single best answer. A declared predictor (`@behaviour Dsxir.Predictor`): it
  augments the signature with one `reasoning_attempt_i :string` input per chain
  plus a prepended `rationale :string` output, then delegates to
  `Dsxir.Predictor.Predict` for a single comparison call.

  The chains are supplied by the caller under the `:completions` input key —
  this predictor does not generate them. `M` is derived from the number of
  completions passed, not declared.

  Each completion may be a `%Dsxir.Prediction{}` or a plain map carrying the
  base signature's output field(s) and an optional `:reasoning`. A chain with
  no `:reasoning` renders without the "I'm trying to ..." clause rather than
  synthesizing one.
  """

  @behaviour Dsxir.Predictor

  alias Dsxir.Prediction
  alias Dsxir.Predictor.Predict
  alias Dsxir.Program.State
  alias Dsxir.Signature.Compiled
  alias Dsxir.Signature.Field
  alias Dsxir.Signature.Runtime

  @comparison_directive "You are given several candidate reasoning attempts. Compare them and produce the single most consistent, best-supported answer."

  @impl Dsxir.Predictor
  def augmented_outputs(_signature), do: [:rationale]

  @impl Dsxir.Predictor
  def forward(%State{} = state, signature, inputs, opts) do
    {completions, base_inputs} = pop_completions!(inputs)
    base_outputs = Runtime.outputs(signature)

    attempt_inputs =
      completions
      |> Enum.with_index(1)
      |> Map.new(fn {completion, i} ->
        {:"reasoning_attempt_#{i}", render_attempt(completion, base_outputs)}
      end)

    augmented = augment(signature, length(completions))
    Predict.forward(state, augmented, Map.merge(base_inputs, attempt_inputs), opts)
  end

  defp pop_completions!(inputs) do
    case Map.pop(inputs, :completions) do
      {[_ | _] = completions, rest} -> {completions, rest}
      _ -> raise ArgumentError, ":completions must be a non-empty list of predictions or maps"
    end
  end

  defp render_attempt(completion, base_outputs) do
    fields = completion_fields(completion)
    prediction = render_outputs(fields, base_outputs)

    case Map.get(fields, :reasoning) do
      nil -> "I'm not sure but my prediction is #{prediction}"
      reasoning -> "I'm trying to #{reasoning}. I'm not sure but my prediction is #{prediction}"
    end
  end

  defp completion_fields(%Prediction{fields: fields}), do: fields
  defp completion_fields(map) when is_map(map), do: map

  defp render_outputs(fields, base_outputs) do
    base_outputs
    |> Enum.map(fn %Field{name: name} -> Map.get(fields, name) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join(", ", &stringify/1)
  end

  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: inspect(value)

  @doc false
  @spec augment(Runtime.signature(), pos_integer()) :: Compiled.t()
  def augment(signature, m) when is_integer(m) and m >= 1 do
    {base_inputs, base_outputs} =
      signature |> Runtime.fields() |> Enum.split_with(&(&1.kind == :input))

    attempt_fields =
      Enum.map(1..m, fn i ->
        %Field{
          name: :"reasoning_attempt_#{i}",
          type: :string,
          zoi: Zoi.string(),
          kind: :input,
          desc: "Candidate reasoning attempt #{i}."
        }
      end)

    rationale = %Field{
      name: :rationale,
      type: :string,
      zoi: Zoi.string(),
      kind: :output,
      desc: "Integrated reasoning that reconciles the candidate attempts."
    }

    %Compiled{
      fields: base_inputs ++ attempt_fields ++ [rationale | base_outputs],
      instruction: instruction(signature),
      source: {:mcc_of, signature}
    }
  end

  defp instruction(signature) do
    case Runtime.instruction(signature) do
      nil -> @comparison_directive
      existing -> existing <> "\n\n" <> @comparison_directive
    end
  end
end
