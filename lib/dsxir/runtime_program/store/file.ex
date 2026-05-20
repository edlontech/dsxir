defmodule Dsxir.RuntimeProgram.Store.File do
  @moduledoc """
  File-backed reference implementation of `Dsxir.RuntimeProgram.Store`.

  One file is written per `{id, version}` under a configured root
  directory. Writes are atomic: the body is staged to a sibling `.tmp.*`
  file and then `File.rename!/2`-d into place.

  Serialization is JSON via `Dsxir.RuntimeProgram.to_artifact_blob/1` and
  `from_artifact_blob/1`; the file is named `<id>_<hex-version>.json`. On
  load, the artifact's predicate sources are re-parsed and the program is
  re-validated — never trust a serialized AST.

  The store performs no concurrency control; file-system semantics
  (atomic rename, single-writer per path) are the contract.
  """

  @behaviour Dsxir.RuntimeProgram.Store

  alias Dsxir.RuntimeProgram
  alias Dsxir.RuntimeProgram.Store

  @ext ".json"

  @impl Dsxir.RuntimeProgram.Store
  def put(root_dir, %RuntimeProgram{} = rp) do
    File.mkdir_p!(root_dir)
    path = ensure_inside!(root_dir, path_for(root_dir, rp.id, rp.version))
    tmp = path <> ".tmp." <> Integer.to_string(:erlang.unique_integer([:positive]))

    body = encode(rp)
    File.write!(tmp, body, [:binary])

    try do
      File.rename!(tmp, path)
    rescue
      e ->
        _ = File.rm(tmp)
        reraise e, __STACKTRACE__
    end

    :ok
  end

  @impl Dsxir.RuntimeProgram.Store
  def get(root_dir, {id, version}) do
    path = ensure_inside!(root_dir, path_for(root_dir, id, version))

    case File.read(path) do
      {:ok, body} -> {:ok, decode(body)}
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, %File.Error{path: path, action: "read", reason: reason}}
    end
  end

  @impl Dsxir.RuntimeProgram.Store
  def list(root_dir, filter) do
    case File.ls(root_dir) do
      {:ok, files} ->
        rps =
          files
          |> Enum.filter(&String.ends_with?(&1, @ext))
          |> Enum.map(fn fname ->
            root_dir |> Path.join(fname) |> File.read!() |> decode()
          end)
          |> Store.apply_filter(filter)

        {:ok, rps}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, %File.Error{path: root_dir, action: "list", reason: reason}}
    end
  end

  defp path_for(root_dir, id, version) do
    Path.join(root_dir, sanitize(id) <> "_" <> Base.encode16(version, case: :lower) <> @ext)
  end

  defp sanitize(id) do
    id
    |> String.replace(~r/[\/\\]/, "_")
    |> String.replace(~r/\.{2,}/, "_")
    |> String.replace(~r/[^A-Za-z0-9._-]/, "_")
  end

  defp ensure_inside!(root_dir, path) do
    root_canon = Path.expand(root_dir)
    file_canon = Path.expand(path)

    if Path.dirname(file_canon) == root_canon do
      file_canon
    else
      raise ArgumentError,
            "computed store path #{inspect(file_canon)} escapes root #{inspect(root_canon)}"
    end
  end

  defp encode(%RuntimeProgram{} = rp) do
    rp
    |> RuntimeProgram.to_artifact_blob()
    |> Jason.encode!()
  end

  defp decode(body) do
    body
    |> Jason.decode!()
    |> RuntimeProgram.from_artifact_blob()
  end
end
