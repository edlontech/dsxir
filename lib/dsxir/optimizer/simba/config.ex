defmodule Dsxir.Optimizer.SIMBA.Config do
  @moduledoc """
  Fills remaining defaults into an expanded SIMBA knob map and validates the
  trainset against the resolved `bsize`.
  """

  alias Dsxir.Errors
  alias Dsxir.Settings

  @defaults %{
    temperature_for_sampling: 0.2,
    temperature_for_candidates: 0.2,
    sampling_temperature: 1.0,
    demo_input_field_maxlen: 100_000,
    num_threads: 4
  }

  @doc """
  Fills remaining defaults into `config` and enforces trainset invariants.

  Returns `{:ok, resolved_config}` on success or
  `{:error, %Errors.Invalid.Trainset{}}` when the trainset is empty or
  shorter than `config.bsize`.
  """
  @spec validate(map(), [Dsxir.Example.t()]) ::
          {:ok, map()} | {:error, Errors.Invalid.Trainset.t()}
  def validate(_config, []) do
    {:error, %Errors.Invalid.Trainset{reason: :empty, example: nil}}
  end

  def validate(config, trainset) do
    resolved =
      @defaults
      |> Map.merge(config)
      |> Map.put_new(:reflective_lm, Settings.resolve(:lm))

    if length(trainset) < resolved.bsize do
      {:error, %Errors.Invalid.Trainset{reason: :too_small, example: nil}}
    else
      {:ok, resolved}
    end
  end
end
