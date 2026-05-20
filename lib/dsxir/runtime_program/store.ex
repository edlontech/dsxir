defmodule Dsxir.RuntimeProgram.Store do
  @moduledoc """
  Behaviour for runtime-program persistence.

  Two reference implementations ship in dsxir:

    * `Dsxir.RuntimeProgram.Store.ETS` - named ETS table owned by a
      supervisor-anchored `GenServer`. Reads and writes bypass the
      `GenServer` and hit the table directly using `:read_concurrency`.
    * `Dsxir.RuntimeProgram.Store.File` - a small file-backed reference
      impl that atomically writes one file per `{id, version}` under a
      configured directory.

  Production users plug their own backend (Postgres, S3, etc.) by
  implementing the three callbacks.

  ## Filter shape

  `list/2` accepts a keyword filter with at most two keys:

    * `:tenant_id` - matches against `metadata.tenant_id`; both string
      (`"tenant_id"`) and atom (`:tenant_id`) keys are supported in the
      program's metadata map.
    * `:id` - exact match against the program's `:id` field.

  No other filters are recognized in v1; extra keys are ignored.
  """

  alias Dsxir.RuntimeProgram

  @type t :: term()
  @type id :: String.t()
  @type version :: <<_::256>>
  @type filter :: keyword()

  @callback put(t(), RuntimeProgram.t()) :: :ok | {:error, term()}
  @callback get(t(), {id(), version()}) ::
              {:ok, RuntimeProgram.t()} | {:error, :not_found}
  @callback list(t(), filter()) :: {:ok, [RuntimeProgram.t()]}

  @doc """
  Filter a list of `%RuntimeProgram{}` structs by a `t:filter/0` keyword.

  Shared helper used by reference impls; production backends may push the
  filter into their query layer instead.
  """
  @spec apply_filter([RuntimeProgram.t()], filter()) :: [RuntimeProgram.t()]
  def apply_filter(rps, filter) do
    tenant = Keyword.get(filter, :tenant_id)
    id = Keyword.get(filter, :id)

    rps
    |> filter_by_tenant(tenant)
    |> filter_by_id(id)
  end

  defp filter_by_tenant(rps, nil), do: rps

  defp filter_by_tenant(rps, tenant) do
    Enum.filter(rps, &(metadata_tenant(&1.metadata) == tenant))
  end

  defp filter_by_id(rps, nil), do: rps
  defp filter_by_id(rps, id), do: Enum.filter(rps, &(&1.id == id))

  defp metadata_tenant(%{} = metadata) do
    case Map.fetch(metadata, "tenant_id") do
      {:ok, v} -> v
      :error -> Map.get(metadata, :tenant_id)
    end
  end

  defp metadata_tenant(_), do: nil
end
