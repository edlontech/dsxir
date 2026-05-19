defmodule Dsxir.OptimizerSession.Checkpoint do
  @moduledoc """
  Persisted record for one OptimizerSession state transition.

  Session-owned structured fields (`progress`, `best_program_artifact`,
  `status`) are readable without invoking the optimizer. The optimizer-owned
  `sampler_blob` is opaque; only the optimizer that wrote it interprets it,
  using `sampler_format = {module, version}` as a refusal gate on resume.
  """

  @enforce_keys [
    :session_id,
    :optimizer,
    :optimizer_opts,
    :trainset_hash,
    :program_module,
    :created_at,
    :updated_at,
    :progress,
    :best_program_artifact,
    :sampler_blob,
    :sampler_format,
    :status
  ]
  defstruct [
    :session_id,
    :optimizer,
    :optimizer_opts,
    :trainset_hash,
    :program_module,
    :created_at,
    :updated_at,
    :progress,
    :best_program_artifact,
    :sampler_blob,
    :sampler_format,
    :status,
    terminal_reason: nil
  ]

  @type trial_log_entry :: %{
          trial_idx: non_neg_integer(),
          candidate_id: String.t() | nil,
          score: float() | nil,
          status: :ok | :error,
          stats: map() | nil,
          duration_ms: non_neg_integer(),
          error: map() | nil,
          error_class: atom() | nil
        }

  @type progress :: %{
          trial_log: [trial_log_entry()],
          best_score: float() | nil,
          best_trial_idx: non_neg_integer() | nil,
          attempts: non_neg_integer(),
          completed: non_neg_integer(),
          errors: non_neg_integer(),
          started_at: DateTime.t()
        }

  @type t :: %__MODULE__{
          session_id: String.t(),
          optimizer: module(),
          optimizer_opts: keyword(),
          trainset_hash: binary(),
          program_module: module(),
          created_at: DateTime.t(),
          updated_at: DateTime.t(),
          progress: progress(),
          best_program_artifact: map() | nil,
          sampler_blob: binary(),
          sampler_format: {module(), pos_integer()},
          status: :running | :paused | :completed | :failed | :cancelled,
          terminal_reason: term()
        }

  @doc """
  Encode `%Checkpoint{}` to a deterministic binary suitable for any Store impl
  that accepts opaque bytes.
  """
  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = cp), do: :erlang.term_to_binary(cp, [:deterministic])

  @doc """
  Decode a binary back to `%Checkpoint{}`. Raises `Dsxir.Errors.Invalid.ResumeMismatch`
  on shape mismatch.
  """
  @spec decode(binary()) :: t()
  def decode(bin) when is_binary(bin) do
    case :erlang.binary_to_term(bin, [:safe]) do
      %__MODULE__{} = cp ->
        cp

      other ->
        raise %Dsxir.Errors.Invalid.ResumeMismatch{
          session_id: "unknown",
          reason: :checkpoint_shape,
          expected: __MODULE__,
          got: inspect(other)
        }
    end
  end

  @doc """
  Build a fresh checkpoint for a brand-new session.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    now = DateTime.utc_now()

    %__MODULE__{
      session_id: Keyword.fetch!(opts, :session_id),
      optimizer: Keyword.fetch!(opts, :optimizer),
      optimizer_opts: Keyword.get(opts, :optimizer_opts, []),
      trainset_hash: Keyword.fetch!(opts, :trainset_hash),
      program_module: Keyword.fetch!(opts, :program_module),
      created_at: now,
      updated_at: now,
      progress: %{
        trial_log: [],
        best_score: nil,
        best_trial_idx: nil,
        attempts: 0,
        completed: 0,
        errors: 0,
        started_at: now
      },
      best_program_artifact: nil,
      sampler_blob: Keyword.fetch!(opts, :sampler_blob),
      sampler_format: Keyword.fetch!(opts, :sampler_format),
      status: :running,
      terminal_reason: nil
    }
  end

  @doc "Hash the trainset for fingerprinting. Stable for byte-identical trainsets."
  @spec hash_trainset([term()]) :: binary()
  def hash_trainset(trainset) when is_list(trainset) do
    :crypto.hash(:sha256, :erlang.term_to_binary(trainset, [:deterministic]))
  end
end
