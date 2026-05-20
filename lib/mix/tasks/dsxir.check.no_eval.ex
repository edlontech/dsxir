defmodule Mix.Tasks.Dsxir.Check.NoEval do
  @moduledoc """
  CI invariant: forbid runtime evaluation/compilation in the dynamic-program code paths.

  Scans:

    * `lib/dsxir/runtime_program/`
    * `lib/dsxir/predicate/`
    * `lib/dsxir/program/source.ex`
    * `lib/dsxir/program/source/runtime_program.ex`

  For these forbidden patterns:

    * `Code.eval_string`, `Code.eval_quoted`
    * `Code.compile_string`, `Code.compile_quoted`
    * `Module.create`
    * `:erl_eval`
    * `String.to_atom` (predicate parser must use `String.to_existing_atom/1`)

  Run via `mix dsxir.check.no_eval`. Exits with status 1 on any hit.

  The repository CI workflow (`.github/workflows/build_and_test.yaml`) invokes
  `mix check`, which in turn runs the custom tool registered in `.check.exs`
  for this task. Local runs can use the task directly.
  """
  use Mix.Task

  @shortdoc "Forbid runtime eval/compile in dynamic-program paths"

  @forbidden [
    "Code.eval_string",
    "Code.eval_quoted",
    "Code.compile_string",
    "Code.compile_quoted",
    "Module.create",
    ":erl_eval",
    "String.to_atom"
  ]

  @scan_paths [
    "lib/dsxir/runtime_program",
    "lib/dsxir/predicate",
    "lib/dsxir/program/source.ex",
    "lib/dsxir/program/source/runtime_program.ex"
  ]

  @impl Mix.Task
  def run(_args) do
    case scan_all() do
      [] ->
        Mix.shell().info("dsxir.check.no_eval: clean.")
        :ok

      hits ->
        Mix.shell().error("dsxir.check.no_eval: forbidden pattern(s) found:")

        Enum.each(hits, fn {file, line, pattern} ->
          Mix.shell().error("  #{file}:#{line}: #{pattern}")
        end)

        System.halt(1)
    end
  end

  @doc """
  Scan all configured paths and return a flat list of `{file, line, pattern}` hits.
  """
  @spec scan_all() :: [{Path.t(), pos_integer(), String.t()}]
  def scan_all do
    Enum.flat_map(@scan_paths, &scan_path_explicit/1)
  end

  @doc """
  Scan a single path (file or directory) and return any hits.

  Returns `[]` when the path does not exist. For directories, every `*.ex`
  file beneath it is scanned recursively.
  """
  @spec scan_path_explicit(Path.t()) :: [{Path.t(), pos_integer(), String.t()}]
  def scan_path_explicit(path) do
    cond do
      File.dir?(path) ->
        [path, "**", "*.ex"]
        |> Path.join()
        |> Path.wildcard()
        |> Enum.flat_map(&scan_file/1)

      File.regular?(path) ->
        scan_file(path)

      true ->
        []
    end
  end

  defp scan_file(file) do
    file
    |> File.stream!()
    |> Enum.with_index(1)
    |> Enum.flat_map(&scan_line(file, &1))
  end

  defp scan_line(file, {line, lineno}) do
    Enum.flat_map(@forbidden, fn pat ->
      if String.contains?(line, pat), do: [{file, lineno, pat}], else: []
    end)
  end
end
