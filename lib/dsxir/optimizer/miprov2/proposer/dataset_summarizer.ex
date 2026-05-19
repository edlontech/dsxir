defmodule Dsxir.Optimizer.MIPROv2.Proposer.DatasetSummarizer do
  @moduledoc """
  Asks the proposer LM to summarize the kind of task represented by a trainset.

  A deterministic sample is taken (sorted by `:erlang.phash2/1`, first
  `:sample_size` examples), rendered as bullets, and fed to the LM. One LM
  call.
  """

  alias Dsxir.Example

  @default_sample_size 5

  @doc """
  Summarize `trainset` via `lm_module`/`lm_config`. Supports the `:sample_size`
  option (default `#{@default_sample_size}`). Returns `{:ok, summary}` or
  `{:error, exception}`.
  """
  @spec run([Example.t()], {module(), keyword()}, keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def run(trainset, {lm_module, lm_config}, opts \\ [])
      when is_list(trainset) and is_atom(lm_module) and is_list(lm_config) and is_list(opts) do
    sample_size = Keyword.get(opts, :sample_size, @default_sample_size)

    rendered =
      trainset
      |> Enum.sort_by(&:erlang.phash2/1)
      |> Enum.take(sample_size)
      |> Enum.with_index(1)
      |> Enum.map_join("\n", &render_one/1)

    prompt = """
    Summarize the kind of task represented by these examples in 2-3 sentences.
    Mention input/output structure and any patterns you notice.

    #{rendered}
    """

    case lm_module.generate_text(lm_config, [%{role: "user", content: prompt}], []) do
      {:ok, text, _usage} -> {:ok, text}
      {:error, exception} -> {:error, exception}
    end
  end

  defp render_one({%Example{data: data}, i}) do
    body =
      Enum.map_join(data, "\n", fn {k, v} -> "  #{k}: #{inspect(v, limit: 60)}" end)

    "Example #{i}:\n#{body}"
  end
end
