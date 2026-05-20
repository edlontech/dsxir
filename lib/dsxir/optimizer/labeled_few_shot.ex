defmodule Dsxir.Optimizer.LabeledFewShot do
  @moduledoc """
  Optimizer that slots up to `:max_labeled_demos` examples from `trainset` into
  each predictor's `Dsxir.Program.State.demos`. No LM call. The metric argument
  is accepted but unused — interface uniformity for richer optimizers.

  ## Multi-predictor pipelines

  A labeled demo is slotted into a predictor only when the demo's data
  keys cover the predictor's declared input + output fields. Trainset
  examples that fit one predictor's signature but not another's are
  routed only to predictors they fit; non-matching predictors get an
  empty labeled-demos list. This keeps saved artifacts well-formed and
  mirrors DSPy's per-predictor demo handling.

  ## Options

    * `:max_labeled_demos` (default `16`) — upper bound on demos per predictor.
      Clamped to `length(trainset)`; no padding.
    * `:deterministic` (default `false`) — when `true`, demo selection is
      reproducible across runs (`Enum.sort_by/2` by `:erlang.phash2/1`, then
      take). When `false`, `Enum.take_random/2` is used.

  ## Returned stats

      %{labeled_demos: non_neg_integer(),
        predictor_count: non_neg_integer(),
        deterministic: boolean()}

  Trainset hash is stored in `program.metadata.trainset_hash` so subsequent
  compiles can detect a trainset change without re-encoding the trainset.

  ## Trainset hash

  `metadata.trainset_hash` is `:crypto.hash(:sha256, :erlang.term_to_binary(trainset)) |> Base.encode16(case: :lower)`.
  The hash is intentionally **permutation-sensitive** and **representation-sensitive**:
  reordering the trainset, or using string keys instead of atom keys in
  `%Dsxir.Example{data: ...}`, will produce a different hash even when the
  labeled content is semantically equal. Use it as a fast change-detector,
  not as a semantic equality oracle. For stable hashing, always use atom keys
  in `Example.data`.
  """

  @behaviour Dsxir.Optimizer

  alias Dsxir.Errors
  alias Dsxir.Program
  alias Dsxir.Signature.Runtime, as: SignatureRuntime

  @default_max_labeled_demos 16

  @impl Dsxir.Optimizer
  def compile(_student, [], _metric, _opts) do
    {:error, %Errors.Invalid.Trainset{reason: :empty, example: nil}}
  end

  def compile(%Program{} = student, trainset, _metric, opts)
      when is_list(trainset) and is_list(opts) do
    case validate_trainset(trainset) do
      :ok ->
        max = Keyword.get(opts, :max_labeled_demos, @default_max_labeled_demos)
        deterministic = Keyword.get(opts, :deterministic, false)
        chosen = pick(trainset, max, deterministic)

        compiled =
          student
          |> slot_demos_for_all(chosen)
          |> stamp_metadata(trainset)

        stats = %{
          labeled_demos: length(chosen),
          predictor_count: map_size(compiled.predictors),
          deterministic: deterministic
        }

        {:ok, compiled, stats}

      {:error, %Errors.Invalid.Trainset{} = err} ->
        {:error, err}
    end
  end

  defp validate_trainset(trainset) do
    case Enum.find(trainset, fn ex -> not match?(%Dsxir.Example{}, ex) end) do
      nil ->
        :ok

      offender ->
        {:error,
         %Errors.Invalid.Trainset{
           reason: :not_an_example,
           example: offender
         }}
    end
  end

  defp pick(trainset, max, true) do
    trainset
    |> Enum.sort_by(&:erlang.phash2/1)
    |> Enum.take(max)
  end

  defp pick(trainset, max, false), do: Enum.take_random(trainset, max)

  defp slot_demos_for_all(%Program{source: source, predictors: predictors} = prog, demos) do
    wrapped = Enum.map(demos, &Dsxir.Demo.labeled/1)
    decls = Dsxir.Program.Source.predictors(source)

    updated =
      Map.new(predictors, fn {name, %Program.State{} = state} ->
        decl = Enum.find(decls, &(&1.name == name))
        compatible = compatible_demos(wrapped, decl)
        {name, %{state | demos: compatible}}
      end)

    %{prog | predictors: updated}
  end

  defp compatible_demos(demos, decl) do
    required = required_field_names(decl)
    Enum.filter(demos, fn demo -> MapSet.subset?(required, demo_key_set(demo)) end)
  end

  defp required_field_names(decl) do
    decl.signature
    |> SignatureRuntime.fields()
    |> Enum.map(& &1.name)
    |> MapSet.new()
  end

  defp demo_key_set(%Dsxir.Demo{example: %Dsxir.Example{data: data}}),
    do: MapSet.new(Map.keys(data))

  defp demo_key_set(%Dsxir.Example{data: data}), do: MapSet.new(Map.keys(data))

  defp stamp_metadata(%Program{} = prog, trainset) do
    metadata =
      prog.metadata
      |> Map.put(:compiled_with, __MODULE__)
      |> Map.put(:score, nil)
      |> Map.put(:trainset_hash, trainset_hash(trainset))

    %{prog | metadata: metadata}
  end

  defp trainset_hash(trainset) do
    :crypto.hash(:sha256, :erlang.term_to_binary(trainset))
    |> Base.encode16(case: :lower)
  end
end
