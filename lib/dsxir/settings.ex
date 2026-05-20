defmodule Dsxir.Settings do
  @moduledoc """
  Three-layer settings stack: globals (`:persistent_term`, with a per-process
  override), per-process scope (process dict), per-call opts (passed as args).

    * `configure/1` writes node-wide globals. Call once at boot.
    * `context/2` pushes a scoped frame for the duration of `fun.()`.
    * `snapshot/0` captures the current globals+stack; `run/2` replays them in a worker.
    * `resolve/2` looks up a key: stack top-down, then globals, then the provided default.

  `run/2` installs the snapshot's globals as a *process-local* override — it never
  writes to `:persistent_term`. Two workers replaying snapshots with different
  globals (different LM, adapter, etc.) cannot observe each other's globals,
  which matters for multi-tenant deployments where each tenant carries its own
  globals view.

  `tenant_*` keys and `:lm` tuples whose config carries a non-nil `:api_key` are rejected
  by `configure/1` with a `Logger.warning`. `tenant_*` keys nested inside `:metadata` are
  stripped from the map with a `Logger.warning`; non-tenant keys in the same map pass through
  unchanged. Per-request tenant data flows through `context/2`.
  The `:lm` field has shape `nil | {impl_module :: module(), config :: keyword()}` (see
  `Dsxir.LM`); credentials live in the config keyword list, not at the top level.
  """

  require Logger

  defstruct lm: nil,
            adapter: nil,
            callbacks: [],
            cache: true,
            call_plugs: [],
            program_plugs: [],
            metadata: %{}

  @type t :: %__MODULE__{
          lm: nil | {module(), keyword()},
          adapter: nil | module(),
          callbacks: list(),
          cache: boolean(),
          call_plugs: list(),
          program_plugs: list(),
          metadata: map()
        }

  @globals_key {__MODULE__, :globals}
  @globals_override_key {__MODULE__, :globals_override}
  @stack_key {__MODULE__, :stack}

  @doc "Architectural defaults installed at application boot."
  @spec default_globals() :: map()
  def default_globals do
    %{
      lm: nil,
      adapter: nil,
      callbacks: [],
      cache: true,
      call_plugs: [],
      program_plugs: [],
      metadata: %{}
    }
  end

  @doc """
  Install globals into `:persistent_term`. Merges with whatever is currently stored;
  unknown keys raise `Dsxir.Errors.Invalid.Configuration`. `tenant_*` keys and `:lm`
  tuples whose config carries a non-nil `:api_key` are dropped with a warning.
  `tenant_*` keys nested inside `:metadata` are stripped from the map (other keys preserved).
  """
  @spec configure(Enumerable.t()) :: :ok
  def configure(opts) do
    sanitised =
      opts
      |> Enum.into(%{})
      |> Enum.flat_map(fn pair ->
        case rejected?(pair) do
          true -> []
          false -> [pair]
          {:rewrite, new_pair} -> [new_pair]
        end
      end)
      |> Map.new()

    Enum.each(sanitised, fn {k, _} ->
      if not Map.has_key?(default_globals(), k) do
        raise %Dsxir.Errors.Invalid.Configuration{
          key: k,
          value: Map.get(sanitised, k),
          reason: :unknown_key
        }
      end
    end)

    current = persistent_globals()
    :persistent_term.put(@globals_key, Map.merge(current, sanitised))
    :ok
  end

  @doc "Push a scoped frame for the duration of `fun.()`. Restored via `try/after`."
  @spec context(Enumerable.t(), (-> any())) :: any()
  def context(frame, fun) when is_function(fun, 0) do
    frame_map = Enum.into(frame, %{})
    stack = stack()
    Process.put(@stack_key, [frame_map | stack])

    try do
      fun.()
    after
      Process.put(@stack_key, stack)
    end
  end

  @doc "Snapshot the live globals and scope stack for replay in another process."
  @spec snapshot() :: %{globals: map(), stack: [map()]}
  def snapshot, do: %{globals: globals(), stack: stack()}

  @doc """
  Replay a snapshot in the calling process for the duration of `fun.()`.

  Installs the snapshot's globals as a *process-local* override and restores the
  scope stack. `:persistent_term` is never written, so concurrent workers
  replaying snapshots with different globals (different LM, adapter, etc.) do
  not leak globals into one another. Both the globals override and the scope
  stack are restored on exit, including when `fun.()` raises.

  Nesting is supported: an inner `run/2` shadows the outer override for the
  duration of its block.
  """
  @spec run(%{globals: map(), stack: [map()]}, (-> any())) :: any()
  def run(%{globals: globals, stack: stack}, fun) when is_function(fun, 0) do
    prior_override = Process.get(@globals_override_key, :__none__)
    prior_stack = stack()

    Process.put(@globals_override_key, globals)
    Process.put(@stack_key, stack)

    try do
      fun.()
    after
      Process.put(@stack_key, prior_stack)
      restore_globals_override(prior_override)
    end
  end

  defp restore_globals_override(:__none__), do: Process.delete(@globals_override_key)
  defp restore_globals_override(map), do: Process.put(@globals_override_key, map)

  @doc "Walk the stack top-down, then globals, then return the default."
  @spec resolve(atom(), term()) :: term()
  def resolve(key, default \\ nil) when is_atom(key) do
    case find_in_stack(stack(), key) do
      {:ok, value} -> value
      :error -> Map.get(globals(), key, default)
    end
  end

  defp find_in_stack([], _key), do: :error

  defp find_in_stack([frame | rest], key) do
    case Map.fetch(frame, key) do
      {:ok, value} -> {:ok, value}
      :error -> find_in_stack(rest, key)
    end
  end

  defp globals do
    case Process.get(@globals_override_key, :__none__) do
      :__none__ -> persistent_globals()
      map -> map
    end
  end

  defp persistent_globals do
    :persistent_term.get(@globals_key, default_globals())
  end

  defp stack do
    Process.get(@stack_key, [])
  end

  defp rejected?({:metadata, %{} = m}) do
    tenant_keys =
      m
      |> Map.keys()
      |> Enum.filter(fn k -> is_atom(k) and String.starts_with?(Atom.to_string(k), "tenant_") end)

    case tenant_keys do
      [] ->
        false

      _ ->
        Logger.warning(
          "Dsxir.Settings.configure/1 rejected tenant_* keys inside :metadata: #{inspect(tenant_keys)}"
        )

        {:rewrite, {:metadata, Map.drop(m, tenant_keys)}}
    end
  end

  defp rejected?({:lm, {_impl, config}}) when is_list(config) do
    if Keyword.get(config, :api_key) do
      Logger.warning(
        "Dsxir.Settings.configure/1 rejected :lm with non-nil api_key; use context/2"
      )

      true
    else
      false
    end
  end

  defp rejected?({key, _value}) when is_atom(key) do
    name = Atom.to_string(key)

    if String.starts_with?(name, "tenant_") do
      Logger.warning("Dsxir.Settings.configure/1 rejected tenant_* key: #{inspect(key)}")
      true
    else
      false
    end
  end

  defp rejected?(_), do: false

  defimpl Inspect do
    import Inspect.Algebra

    @sensitive_keys [:api_key, :token, :password, :secret]

    def inspect(%Dsxir.Settings{} = settings, opts) do
      concat([
        "#Dsxir.Settings<",
        to_doc(
          %{
            lm: mask_lm(settings.lm),
            adapter: settings.adapter,
            callbacks: length(settings.callbacks),
            cache: settings.cache,
            call_plugs: length(settings.call_plugs),
            program_plugs: length(settings.program_plugs),
            metadata: settings.metadata
          },
          opts
        ),
        ">"
      ])
    end

    defp mask_lm(nil), do: nil

    defp mask_lm({impl, config}) when is_list(config) do
      masked =
        Enum.map(config, fn
          {k, _v} when k in @sensitive_keys -> {k, "[FILTERED]"}
          pair -> pair
        end)

      {impl, masked}
    end
  end
end
