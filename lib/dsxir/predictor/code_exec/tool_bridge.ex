defmodule Dsxir.Predictor.CodeExec.ToolBridge do
  @moduledoc """
  Exposes user `Dsxir.Tool`s to sandboxed CodeAct code.

  `build/1` registers the tool set in the named public ETS table under a unique
  token and returns `{token, prelude, prompt_fragment}`. The prelude binds the
  token as a sandbox variable; the model calls
  `Dsxir.Predictor.CodeExec.ToolBridge.call(token, name, args)` from inside the
  sandbox, using the fully-qualified module name since the sandbox has no alias
  for it. `call/3` is the only function exposed to the sandbox via
  `Dsxir.Predictor.CodeExec.ToolAllowlist`; it runs with full privileges
  (allowed, not shimmed) and dispatches to the real tool. User tools are
  trusted, exactly as in `Dsxir.Predictor.ReAct`.

  This module is also the supervised owner of the `:dsxir_codeact_tools` ETS
  table: it creates the table at boot and holds it for the lifetime of the
  application, mirroring `Dsxir.History`.

  **Caller-owned cleanup:** every `build/1` call inserts a token entry that
  persists until `cleanup/1` (or `cleanup_all/0`) is called; callers must clean
  up after each use to avoid unbounded registry growth.

  **Cross-call isolation:** each call's tools are keyed by an unguessable
  random token that is bound only inside that call's sandbox prelude, so one
  sandbox cannot reach another call's tools without knowing its token.
  """

  use GenServer

  alias Dsxir.Primitives.Tool

  @table :dsxir_codeact_tools

  @doc "Start the tool-registry owner as a named singleton."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @spec build([Tool.t()]) :: {String.t(), String.t(), String.t()}
  def build(tools) do
    ensure_table()
    token = token()
    by_name = Map.new(tools, fn %Tool{name: name} = t -> {name, t} end)
    prelude = ~s|__dsxir_tools__ = "#{token}"|
    prompt = prompt_fragment(tools)
    :ets.insert(@table, {token, by_name})
    {token, prelude, prompt}
  end

  @spec call(String.t(), String.t(), map()) :: String.t()
  def call(token, name, args) do
    case lookup(token, name) do
      {:ok, tool} ->
        case Tool.execute(tool, args) do
          {:ok, value} -> value
          {:error, e} -> "Execution error in #{name}: #{Exception.message(e)}"
        end

      :error ->
        "Unknown tool: #{name}"
    end
  end

  @spec cleanup(String.t()) :: :ok
  def cleanup(token) do
    ensure_table()
    :ets.delete(@table, token)
    :ok
  end

  @doc false
  def cleanup_all do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  defp lookup(token, name) do
    ensure_table()

    case :ets.lookup(@table, token) do
      [{^token, by_name}] -> Map.fetch(by_name, name)
      [] -> :error
    end
  end

  defp prompt_fragment([]), do: ""

  defp prompt_fragment(tools) do
    lines = Enum.map_join(tools, "\n", fn %Tool{name: n, description: d} -> "  - #{n}: #{d}" end)

    """
    You may call these tools from your code with:

        Dsxir.Predictor.CodeExec.ToolBridge.call(__dsxir_tools__, name, args)

    Rules, follow them exactly:
      - Use that fully-qualified module name; there is no alias for it.
      - `name` is the tool name as a string (e.g. "#{example_name(tools)}"), not an atom.
      - `args` is a map of arguments for that tool.
      - The call returns the tool's result as a plain string. It does not return
        an {:ok, _} tuple or a struct. Parse it yourself if you need a number,
        e.g. with String.to_integer/1 or String.to_float/1.

    Available tools:
    #{lines}\
    """
  end

  defp example_name([%Tool{name: name} | _]), do: name

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

      _ref ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  defp token, do: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
end
