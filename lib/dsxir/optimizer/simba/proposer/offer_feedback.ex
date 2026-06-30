defmodule Dsxir.Optimizer.SIMBA.Proposer.OfferFeedback do
  @moduledoc """
  Internal signature and trace helpers for the SIMBA `AppendRule` strategy.
  Given a better-vs-worse trajectory pair for the same input, the reflective LM
  produces per-module advice that gets appended to each predictor's instruction.
  Not a user-facing signature.
  """

  alias Dsxir.Signature.Compiled
  alias Dsxir.Signature.Field
  alias Dsxir.Trace.Entry

  @instruction """
  You are given two trajectories of an LLM-driven program: one that scored \
  higher and one that scored lower on the same input. Compare them and, for \
  each module named below, give one concrete, generalizable instruction that \
  would make the module behave like the better trajectory rather than the \
  worse one. Ground every recommendation in the contrast between the two \
  trajectories. Keep advice specific to that module's sub-task, avoid \
  boilerplate, and reference each module name exactly once.
  """

  @doc "The internal OfferFeedback signature run by the AppendRule strategy."
  @spec signature() :: Compiled.t()
  def signature do
    %Compiled{
      fields: fields(),
      instruction: @instruction,
      source: {:offer_feedback, __MODULE__}
    }
  end

  defp fields do
    [
      %Field{
        name: :program_inputs,
        type: :string,
        zoi: Zoi.string(),
        kind: :input,
        desc: "The inputs to the program we are analyzing."
      },
      %Field{
        name: :oracle_metadata,
        type: :string,
        zoi: Zoi.string(),
        kind: :input,
        desc: "Any hidden metadata about the training instance."
      },
      %Field{
        name: :better_program_trajectory,
        type: :string,
        zoi: Zoi.string(),
        kind: :input,
        desc: "Per-module inputs and outputs from the higher-scoring run."
      },
      %Field{
        name: :better_program_outputs,
        type: :string,
        zoi: Zoi.string(),
        kind: :input,
        desc: "The final outputs of the higher-scoring run."
      },
      %Field{
        name: :better_reward_value,
        type: :number,
        zoi: Zoi.number(),
        kind: :input,
        desc: "The reward assigned to the higher-scoring run."
      },
      %Field{
        name: :better_reward_info,
        type: :string,
        zoi: Zoi.string(),
        kind: :input,
        desc: "Extra information explaining the higher reward."
      },
      %Field{
        name: :worse_program_trajectory,
        type: :string,
        zoi: Zoi.string(),
        kind: :input,
        desc: "Per-module inputs and outputs from the lower-scoring run."
      },
      %Field{
        name: :worse_program_outputs,
        type: :string,
        zoi: Zoi.string(),
        kind: :input,
        desc: "The final outputs of the lower-scoring run."
      },
      %Field{
        name: :worse_reward_value,
        type: :number,
        zoi: Zoi.number(),
        kind: :input,
        desc: "The reward assigned to the lower-scoring run."
      },
      %Field{
        name: :worse_reward_info,
        type: :string,
        zoi: Zoi.string(),
        kind: :input,
        desc: "Extra information explaining the lower reward."
      },
      %Field{
        name: :module_names,
        type: {:list, :string},
        zoi: Zoi.list(Zoi.string()),
        kind: :input,
        desc: "The names of the modules for which we seek advice."
      },
      %Field{
        name: :discussion,
        type: :string,
        zoi: Zoi.string(),
        kind: :output,
        desc: "Discussion of where each module went wrong, if it did."
      },
      %Field{
        name: :advice,
        type: {:list, :map},
        zoi: advice_zoi(),
        kind: :output,
        desc: "One {module, advice} per module, each module named once."
      }
    ]
  end

  defp advice_zoi do
    Zoi.list(Zoi.object(%{module: Zoi.string(), advice: Zoi.string()}))
  end

  @doc "Render a captured trace into a per-module trajectory string."
  @spec render_trajectory([Entry.t()]) :: String.t()
  def render_trajectory(trace) do
    Enum.map_join(trace, "\n\n", fn %Entry{predictor: name, inputs: inputs, prediction: pred} ->
      "## #{name}\ninputs: #{inspect(inputs)}\noutputs: #{inspect(pred.fields)}"
    end)
  end

  @doc "Unique predictor names from the trace, in first-seen order, as strings."
  @spec module_names([Entry.t()]) :: [String.t()]
  def module_names(trace) do
    trace |> Enum.map(&to_string(&1.predictor)) |> Enum.uniq()
  end

  @doc """
  Turn the LM's advice output (a list of `%{module, advice}` maps) into a
  `%{module_name => advice}` map. Tolerates string or atom keys. Malformed or
  empty input yields `%{}` and never raises.
  """
  @spec parse(term()) :: %{optional(String.t()) => String.t()}
  def parse(advice) when is_list(advice) do
    Enum.reduce(advice, %{}, fn entry, acc ->
      case extract(entry) do
        {name, text} -> Map.put(acc, name, text)
        :error -> acc
      end
    end)
  end

  def parse(_), do: %{}

  defp extract(entry) when is_map(entry) do
    module = fetch(entry, "module", :module)
    text = fetch(entry, "advice", :advice)

    if is_binary(module) and module != "" and is_binary(text) do
      {module, text}
    else
      :error
    end
  end

  defp extract(_), do: :error

  defp fetch(map, string_key, atom_key) do
    case map do
      %{^string_key => v} -> v
      %{^atom_key => v} -> v
      _ -> nil
    end
  end

  @doc """
  Recursively replace non-JSON-serializable terms with a placeholder string,
  leaving maps, lists, tuples, and serializable scalars intact. Mirrors DSPy's
  `recursive_mask`, used to safely render arbitrary input/metadata values.
  """
  @spec recursive_mask(term()) :: term()
  def recursive_mask(term) do
    if serializable?(term), do: term, else: mask(term)
  end

  defp serializable?(term) do
    match?({:ok, _}, Jason.encode(term))
  end

  defp mask(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {k, v} -> {k, recursive_mask(v)} end)
  end

  defp mask(list) when is_list(list) do
    Enum.map(list, &recursive_mask/1)
  end

  defp mask(tuple) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.map(&recursive_mask/1) |> List.to_tuple()
  end

  defp mask(other), do: "<non-serializable: #{type_name(other)}>"

  defp type_name(term) when is_pid(term), do: "PID"
  defp type_name(term) when is_function(term), do: "Function"
  defp type_name(term) when is_reference(term), do: "Reference"
  defp type_name(term) when is_port(term), do: "Port"
  defp type_name(%mod{}), do: inspect(mod)
  defp type_name(_), do: "term"
end
