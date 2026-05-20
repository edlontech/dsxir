defmodule Dsxir.RuntimeProgram.Topological do
  @moduledoc """
  Kahn's algorithm for sorting `%Dsxir.RuntimeProgram.Node{}` values into a
  valid execution order.

  Only `{:node, _, _} -> {:node, _, _}` edges contribute to the dependency
  graph; `program_input`, `program_output`, and `const` endpoints are not
  inter-node dependencies. Returns `{:ok, [name]}` on success or
  `{:error, {:cycle, [name]}}` listing the remaining nodes when a cycle is
  detected. The validator already proves runtime programs are acyclic, so the
  error path is for robustness only.
  """

  alias Dsxir.RuntimeProgram.Edge
  alias Dsxir.RuntimeProgram.Node, as: RPNode

  @doc """
  Sort `nodes` topologically using `edges`. Only node-to-node edges
  contribute to dependencies.

  Linear-time Kahn implementation: builds an in-degree counter map and a
  forward-adjacency map, then drains nodes whose in-degree is zero one at a
  time, decrementing the in-degree of their children. Determinism is
  preserved by seeding the work queue from the input `nodes` order and
  appending newly-ready children in the order their parents are processed.
  """
  @spec sort([RPNode.t()], [Edge.t()]) ::
          {:ok, [atom()]} | {:error, {:cycle, [atom()]}}
  def sort(nodes, edges) when is_list(nodes) and is_list(edges) do
    node_names = Enum.map(nodes, & &1.name)
    node_set = MapSet.new(node_names)
    {adjacency, in_degree} = build_graph(edges, node_set, node_names)

    initial_zero = for n <- node_names, Map.fetch!(in_degree, n) == 0, do: n
    queue = :queue.from_list(initial_zero)

    drain(queue, adjacency, in_degree, [], node_names)
  end

  defp build_graph(edges, node_set, node_names) do
    base_indegree = Map.new(node_names, &{&1, 0})

    Enum.reduce(edges, {%{}, base_indegree}, fn
      %Edge{from: {:node, src, _}, to: {:node, dst, _}}, {adj, deg} = acc ->
        if MapSet.member?(node_set, src) and MapSet.member?(node_set, dst) do
          adj = Map.update(adj, src, [dst], &[dst | &1])
          deg = Map.update!(deg, dst, &(&1 + 1))
          {adj, deg}
        else
          acc
        end

      _, acc ->
        acc
    end)
    |> reverse_adjacency()
  end

  defp reverse_adjacency({adj, deg}) do
    {Map.new(adj, fn {k, v} -> {k, Enum.reverse(v)} end), deg}
  end

  defp drain(queue, adj, in_degree, acc, node_names) do
    case :queue.out(queue) do
      {:empty, _} -> finalize(acc, in_degree, node_names)
      {{:value, head}, rest_queue} -> step(head, rest_queue, adj, in_degree, acc, node_names)
    end
  end

  defp finalize(acc, in_degree, node_names) do
    if length(acc) == length(node_names) do
      {:ok, Enum.reverse(acc)}
    else
      remaining = for n <- node_names, Map.get(in_degree, n, 0) > 0, do: n
      {:error, {:cycle, remaining}}
    end
  end

  defp step(head, rest_queue, adj, in_degree, acc, node_names) do
    {new_queue, new_in_degree} =
      adj
      |> Map.get(head, [])
      |> Enum.reduce({rest_queue, in_degree}, &visit_child/2)

    drain(new_queue, adj, new_in_degree, [head | acc], node_names)
  end

  defp visit_child(child, {q, deg}) do
    new_value = Map.fetch!(deg, child) - 1
    deg = Map.put(deg, child, new_value)

    if new_value == 0 do
      {:queue.in(child, q), deg}
    else
      {q, deg}
    end
  end
end
