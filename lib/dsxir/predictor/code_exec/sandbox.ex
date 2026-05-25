defmodule Dsxir.Predictor.CodeExec.Sandbox do
  @moduledoc """
  Wraps `Dune.eval_string/2`. The only module in dsxir that references `Dune`.

  Inputs are injected as a bindings prelude: each `{name, value}` becomes a
  bound variable `name = <inspected value>` prepended to the generated code,
  so generated code references the signature's input fields by name. The value
  of the last expression is the result.

  ## Bindings round-trip limitation

  Binding values are serialised via `inspect/1` and re-parsed inside the Dune
  sandbox. This only works for terms whose `inspect/1` output is valid Elixir
  source: strings, numbers, atoms, booleans, lists, and plain maps. Structs
  whose `Inspect` implementation emits a `#`-sigil representation (e.g.
  `#Dsxir.Primitives.History<...>`) are **not** supported as bindings, nor are
  PIDs, references, or anonymous functions.

  ## Recognised opts

  The following keys are forwarded to Dune; all other keys are ignored:
  `exec_timeout`, `max_heap_size`, `max_reductions`, `atom_pool_size`, and
  `allowlist`.
  """

  @default_opts [
    exec_timeout: 5_000,
    max_heap_size: 200_000,
    max_reductions: 30_000_000,
    atom_pool_size: 5_000,
    allowlist: Dune.Allowlist.Default
  ]

  @doc """
  Evaluates `code` in the Dune sandbox with `bindings` prepended as a prelude.

  Returns `{:ok, %{value, inspected, stdio}}` on success, or
  `{:error, %{type, message, stdio}}` where `type` is the Dune failure type
  (`:restricted`, `:timeout`, `:exception`, `:parsing`, `:memory`,
  `:reductions`, etc.).
  """
  @spec eval(String.t(), keyword(), keyword()) ::
          {:ok, %{value: term(), inspected: String.t(), stdio: String.t()}}
          | {:error, %{type: atom(), message: String.t(), stdio: String.t()}}
  def eval(code, bindings, opts) when is_binary(code) do
    full =
      case prelude(bindings) do
        "" -> code
        p -> p <> "\n" <> code
      end

    case Dune.eval_string(full, dune_opts(opts)) do
      %Dune.Success{value: value, inspected: inspected, stdio: stdio} ->
        {:ok, %{value: value, inspected: inspected, stdio: stdio}}

      %Dune.Failure{type: type, message: message, stdio: stdio} ->
        {:error, %{type: type, message: message, stdio: stdio}}
    end
  end

  defp prelude([]), do: ""

  defp prelude(bindings) do
    Enum.map_join(bindings, "\n", fn {name, value} -> "#{name} = #{inspect(value)}" end)
  end

  defp dune_opts(opts) do
    merged = Keyword.merge(@default_opts, opts)

    [
      timeout: merged[:exec_timeout],
      max_heap_size: merged[:max_heap_size],
      max_reductions: merged[:max_reductions],
      atom_pool_size: merged[:atom_pool_size],
      allowlist: merged[:allowlist]
    ]
  end
end
