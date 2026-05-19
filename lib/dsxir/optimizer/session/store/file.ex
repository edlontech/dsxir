defmodule Dsxir.OptimizerSession.Store.File do
  @moduledoc """
  File-backed Store with atomic writes (temp file plus rename).

  ## Options

    * `:dir` (required) - directory holding `<session_id>.<ext>` files.
      The directory is created on first write.
    * `:format` (`:binary` default, `:json` for debugging) - encoding for the
      checkpoint body. `:binary` is `:erlang.term_to_binary/2 [:deterministic]`;
      `:json` is `JSON.encode!/1` with `sampler_blob` Base64-wrapped.

  Format guarantees:

    * `:binary` - full round-trip fidelity for any Elixir term, suitable for
      resume.
    * `:json` - mostly human-readable, but `optimizer_opts` is opaquely
      wrapped as a Base64-encoded `:erlang.term_to_binary/2` blob so the
      checkpoint can still resume sessions whose options contain non-JSON
      terms (tuples, atoms-as-values, function refs, etc.).
  """

  @behaviour Dsxir.OptimizerSession.Store

  alias Dsxir.OptimizerSession.Checkpoint

  @impl true
  def put_checkpoint(opts, session_id, %Checkpoint{} = cp) do
    dir = Keyword.fetch!(opts, :dir)
    format = Keyword.get(opts, :format, :binary)
    File.mkdir_p!(dir)

    path = path_for(dir, session_id, format)
    tmp = path <> ".tmp." <> Integer.to_string(:erlang.unique_integer([:positive]))

    body = encode_body(cp, format)
    File.write!(tmp, body, [:binary])
    File.rename!(tmp, path)
    :ok
  end

  @impl true
  def get_checkpoint(opts, session_id) do
    dir = Keyword.fetch!(opts, :dir)
    format = Keyword.get(opts, :format, :binary)
    path = path_for(dir, session_id, format)

    case File.read(path) do
      {:ok, body} -> {:ok, decode_body(body, format)}
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, %File.Error{path: path, action: "read", reason: reason}}
    end
  end

  @impl true
  def list_sessions(opts, filter) do
    dir = Keyword.fetch!(opts, :dir)
    format = Keyword.get(opts, :format, :binary)

    case File.ls(dir) do
      {:ok, files} ->
        ext = ext_for(format)

        listings =
          files
          |> Enum.filter(&String.ends_with?(&1, ext))
          |> Enum.map(fn fname ->
            id = Path.rootname(fname, ext)
            {:ok, cp} = get_checkpoint(opts, id)
            to_listing(cp)
          end)
          |> filter_listings(filter)

        {:ok, listings}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, %File.Error{path: dir, action: "list", reason: reason}}
    end
  end

  @impl true
  def delete_checkpoint(opts, session_id) do
    dir = Keyword.fetch!(opts, :dir)
    format = Keyword.get(opts, :format, :binary)
    path = path_for(dir, session_id, format)

    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, %File.Error{path: path, action: "remove", reason: reason}}
    end
  end

  defp encode_body(cp, :binary), do: Checkpoint.encode(cp)

  defp encode_body(cp, :json) do
    cp
    |> Map.from_struct()
    |> Map.update!(:sampler_blob, &Base.encode64/1)
    |> Map.update!(:trainset_hash, &Base.encode16(&1, case: :lower))
    |> Map.update!(:optimizer, &Atom.to_string/1)
    |> Map.update!(:program_module, &Atom.to_string/1)
    |> Map.update!(:sampler_format, fn {m, v} -> [Atom.to_string(m), v] end)
    |> Map.update!(:created_at, &DateTime.to_iso8601/1)
    |> Map.update!(:updated_at, &DateTime.to_iso8601/1)
    |> Map.update!(:status, &Atom.to_string/1)
    |> Map.update!(:progress, &encode_progress/1)
    |> Map.update!(:optimizer_opts, &encode_optimizer_opts/1)
    |> JSON.encode!()
  end

  defp encode_optimizer_opts(opts) do
    %{
      "_format" => "binary_base64",
      "value" => Base.encode64(:erlang.term_to_binary(opts, [:deterministic]))
    }
  end

  defp encode_progress(progress) do
    progress
    |> Map.update!(:started_at, &DateTime.to_iso8601/1)
    |> Map.update!(:trial_log, fn entries -> Enum.map(entries, &encode_trial_entry/1) end)
  end

  defp encode_trial_entry(%{} = entry) do
    entry
    |> maybe_struct_to_map()
    |> Map.update(:error, nil, &encode_trial_error/1)
  end

  defp maybe_struct_to_map(%_{} = s), do: Map.from_struct(s)
  defp maybe_struct_to_map(%{} = m), do: m

  defp encode_trial_error(nil), do: nil
  defp encode_trial_error(%_{} = err), do: Map.from_struct(err)
  defp encode_trial_error(other), do: other

  defp decode_body(body, :binary), do: Checkpoint.decode(body)

  defp decode_body(body, :json) do
    raw = JSON.decode!(body)

    %Checkpoint{
      session_id: Map.fetch!(raw, "session_id"),
      optimizer: String.to_existing_atom(Map.fetch!(raw, "optimizer")),
      optimizer_opts: decode_optimizer_opts(Map.get(raw, "optimizer_opts", [])),
      trainset_hash: Base.decode16!(Map.fetch!(raw, "trainset_hash"), case: :lower),
      program_module: String.to_existing_atom(Map.fetch!(raw, "program_module")),
      created_at: parse_iso8601!(Map.fetch!(raw, "created_at")),
      updated_at: parse_iso8601!(Map.fetch!(raw, "updated_at")),
      progress: decode_progress(Map.fetch!(raw, "progress")),
      best_program_artifact: Map.get(raw, "best_program_artifact"),
      sampler_blob: Base.decode64!(Map.fetch!(raw, "sampler_blob")),
      sampler_format: decode_sampler_format(Map.fetch!(raw, "sampler_format")),
      status: String.to_existing_atom(Map.fetch!(raw, "status")),
      terminal_reason: Map.get(raw, "terminal_reason")
    }
  end

  defp decode_progress(p) do
    %{
      trial_log: Map.get(p, "trial_log", []),
      best_score: Map.get(p, "best_score"),
      best_trial_idx: Map.get(p, "best_trial_idx"),
      attempts: Map.fetch!(p, "attempts"),
      completed: Map.fetch!(p, "completed"),
      errors: Map.fetch!(p, "errors"),
      started_at: parse_iso8601!(Map.fetch!(p, "started_at"))
    }
  end

  defp decode_sampler_format([m, v]), do: {String.to_existing_atom(m), v}

  defp decode_optimizer_opts(%{"_format" => "binary_base64", "value" => v64}) do
    v64 |> Base.decode64!() |> :erlang.binary_to_term([:safe])
  end

  defp decode_optimizer_opts(list) when is_list(list), do: list
  defp decode_optimizer_opts(other), do: other

  defp parse_iso8601!(str) do
    {:ok, dt, _offset} = DateTime.from_iso8601(str)
    dt
  end

  defp path_for(dir, id, format), do: Path.join(dir, id <> ext_for(format))
  defp ext_for(:binary), do: ".bin"
  defp ext_for(:json), do: ".json"

  defp to_listing(%Checkpoint{} = cp) do
    %{
      session_id: cp.session_id,
      status: cp.status,
      updated_at: cp.updated_at,
      optimizer: cp.optimizer,
      best_score: cp.progress.best_score
    }
  end

  defp filter_listings(listings, filter) do
    status_filter = Keyword.get(filter, :status)
    optimizer_filter = Keyword.get(filter, :optimizer)
    updated_since = Keyword.get(filter, :updated_since)

    Enum.filter(listings, fn l ->
      (is_nil(status_filter) or l.status == status_filter) and
        (is_nil(optimizer_filter) or l.optimizer == optimizer_filter) and
        (is_nil(updated_since) or DateTime.compare(l.updated_at, updated_since) != :lt)
    end)
  end
end
