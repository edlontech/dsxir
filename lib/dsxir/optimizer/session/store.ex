defmodule Dsxir.OptimizerSession.Store do
  @moduledoc """
  Behaviour for OptimizerSession checkpoint persistence.

  Two reference implementations ship in dsxir:

    * `Dsxir.OptimizerSession.Store.ETS` - named table, in-memory, application-supervised.
    * `Dsxir.OptimizerSession.Store.File` - JSON or binary files with atomic temp-file-plus-rename writes.

  Consumers wire their own Postgres / S3 / etc by implementing the four callbacks.
  """

  alias Dsxir.OptimizerSession.Checkpoint

  @type session_id :: String.t()
  @type opts :: keyword()
  @type filter :: keyword()
  @type store_spec :: :ets | :file | {module(), keyword()}
  @type listing :: %{
          session_id: session_id(),
          status: atom(),
          updated_at: DateTime.t(),
          optimizer: module(),
          best_score: float() | nil
        }

  @callback put_checkpoint(opts(), session_id(), Checkpoint.t()) :: :ok | {:error, term()}
  @callback get_checkpoint(opts(), session_id()) ::
              {:ok, Checkpoint.t()} | {:error, :not_found | term()}
  @callback list_sessions(opts(), filter()) :: {:ok, [listing()]} | {:error, term()}
  @callback delete_checkpoint(opts(), session_id()) :: :ok | {:error, term()}

  @doc """
  Resolve a `store:` option shortcut into a `{module, opts}` tuple.

  Accepts:

    * `:ets` -> `{Dsxir.OptimizerSession.Store.ETS, []}`
    * `:file` -> `{Dsxir.OptimizerSession.Store.File, dir: "priv/dsxir/sessions", format: :binary}`
    * `{module, opts}` -> passed through.

  Honors `Application.get_env(:dsxir, :default_session_store, ...)` for default override.
  The compile-time default is configured via `config :dsxir, :default_session_store, ...`
  (defaults to `:file` outside of test).
  """
  @default_store Application.compile_env(:dsxir, :default_session_store, :file)

  @spec resolve(:ets | :file | {module(), keyword()} | nil) :: {module(), keyword()}
  def resolve(nil) do
    :dsxir
    |> Application.get_env(:default_session_store, @default_store)
    |> resolve()
  end

  def resolve(:ets), do: {__MODULE__.ETS, []}

  def resolve(:file) do
    {__MODULE__.File, dir: "priv/dsxir/sessions", format: :binary}
  end

  def resolve({mod, opts}) when is_atom(mod) and is_list(opts), do: {mod, opts}
end
