defmodule Dsxir.OptimizerSession.SecurityTest do
  use ExUnit.Case, async: false

  alias Dsxir.OptimizerSession
  alias Dsxir.Settings
  alias Dsxir.Test.Fixtures.AnswerProgram
  alias Dsxir.Test.Fixtures.MimicOptimizer

  setup do
    on_exit(fn ->
      case :ets.whereis(:dsxir_optimizer_sessions) do
        :undefined -> :ok
        _ -> :ets.delete_all_objects(:dsxir_optimizer_sessions)
      end
    end)

    :ok
  end

  defp dummy_program, do: Dsxir.Program.new(AnswerProgram)
  defp dummy_metric, do: fn _ex, _pred, _trace -> 0.0 end

  test "persisted checkpoints contain no api_key, LM credentials, or tenant_id values" do
    fake_api_key = "sk-CREDENTIAL-PROBE-#{System.unique_integer([:positive])}"
    tenant_value = "tenant_TARGET-#{System.unique_integer([:positive])}"

    Settings.context(
      [
        lm: {Dsxir.LM.Sycophant, [model: "openai:gpt-4o-mini", api_key: fake_api_key]},
        metadata: %{tenant_id: tenant_value, request_id: "req_42"}
      ],
      fn ->
        {:ok, _, _} =
          OptimizerSession.compile(
            MimicOptimizer,
            dummy_program(),
            [%{x: 1}],
            dummy_metric(),
            scripted_scores: [0.5, 0.6, 0.7]
          )
      end
    )

    {:ok, sessions} = OptimizerSession.list_sessions(:ets)
    assert sessions != []

    Enum.each(sessions, fn %{session_id: id} ->
      {:ok, cp} = Dsxir.OptimizerSession.Store.ETS.get_checkpoint([], id)
      blob = :erlang.term_to_binary(cp, [:deterministic])
      blob_str = inspect(blob, limit: :infinity, printable_limit: :infinity)

      refute String.contains?(blob_str, fake_api_key),
             "checkpoint #{id} contains api_key value"

      refute String.contains?(blob_str, tenant_value),
             "checkpoint #{id} contains tenant_id value"

      refute checkpoint_contains_lm_tuple?(cp),
             "checkpoint #{id} contains an LM tuple in its struct"
    end)
  end

  defp checkpoint_contains_lm_tuple?(term) do
    walk_term(term, fn
      {mod, config} when is_atom(mod) and is_list(config) ->
        Keyword.has_key?(config, :api_key)

      _ ->
        false
    end)
  end

  defp walk_term(term, pred) do
    cond do
      pred.(term) ->
        true

      is_map(term) ->
        term
        |> Map.delete(:__struct__)
        |> Map.to_list()
        |> Enum.any?(fn {k, v} -> walk_term(k, pred) or walk_term(v, pred) end)

      is_list(term) ->
        Enum.any?(term, &walk_term(&1, pred))

      is_tuple(term) ->
        term |> Tuple.to_list() |> Enum.any?(&walk_term(&1, pred))

      true ->
        false
    end
  end
end
