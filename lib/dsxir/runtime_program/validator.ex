defmodule Dsxir.RuntimeProgram.Validator do
  @moduledoc """
  Three-phase semantic validator for `%Dsxir.RuntimeProgram{}`.

  Errors from one phase do not suppress the next. Within a phase, errors
  accumulate across independent units (per-node, per-edge, per-guard).

    * Phase 1 (structural): unique node names, impl/signature resolvable,
      edge endpoints reference real nodes and fields, every program output
      has an inbound edge, DAG is acyclic, no required input is dangling.
    * Phase 2 (guards): per-node, parse the guard source then type-check
      the resulting AST against an upstream-only environment. Successful
      ASTs are attached to the node via `Dsxir.Predicate.Source.attach_ast/2`.
    * Phase 3 (types): per-edge structural type compatibility between
      producer and consumer fields. `:any` is a universal top.

  On `:ok` the returned `%RuntimeProgram{}` has guard ASTs attached so the
  executor does not need to re-parse.
  """

  alias Dsxir.Errors.Invalid
  alias Dsxir.Predicate
  alias Dsxir.RuntimeProgram
  alias Dsxir.RuntimeProgram.Edge
  alias Dsxir.RuntimeProgram.FieldSpec
  alias Dsxir.RuntimeProgram.Node, as: RPNode
  alias Dsxir.Signature.Compiled
  alias Dsxir.Signature.Runtime

  @doc """
  Run the three-phase validator over `rp`. Returns `{:ok, rewritten_rp}` on
  success (guard ASTs attached), or `{:error, %Invalid.RuntimeProgram{}}`
  carrying the accumulated errors.
  """
  @spec validate(RuntimeProgram.t()) ::
          {:ok, RuntimeProgram.t()} | {:error, Invalid.RuntimeProgram.t()}
  def validate(%RuntimeProgram{} = rp) do
    structural_errors = phase1_structural(rp)
    {rp_with_asts, guard_errors} = phase2_guards(rp)
    type_errors = phase3_types(rp_with_asts)

    case structural_errors ++ guard_errors ++ type_errors do
      [] -> {:ok, rp_with_asts}
      errors -> {:error, %Invalid.RuntimeProgram{errors: errors}}
    end
  end

  # ---- Phase 1 ----------------------------------------------------------

  defp phase1_structural(rp) do
    Enum.concat([
      check_unique_node_names(rp),
      check_predictor_impls(rp),
      check_signatures(rp),
      check_edge_references(rp),
      check_program_output_reachability(rp),
      check_dag_acyclic(rp),
      check_dangling_required_inputs(rp)
    ])
  end

  defp check_unique_node_names(%RuntimeProgram{nodes: nodes}) do
    nodes
    |> Enum.map(& &1.name)
    |> Enum.frequencies()
    |> Enum.flat_map(fn
      {_name, 1} ->
        []

      {name, n} when n > 1 ->
        for _ <- 1..(n - 1) do
          %{
            path: [:nodes, name],
            code: :duplicate_node_name,
            message: "duplicate node name #{inspect(name)}",
            suggestion: nil
          }
        end
    end)
  end

  defp check_predictor_impls(%RuntimeProgram{nodes: nodes}) do
    Enum.flat_map(nodes, fn %RPNode{name: name, impl: impl} ->
      cond do
        not is_atom(impl) ->
          [
            %{
              path: [:nodes, name, :impl],
              code: :unknown_impl,
              message: "node impl must be a module atom, got: #{inspect(impl)}",
              suggestion: nil
            }
          ]

        not Code.ensure_loaded?(impl) ->
          [
            %{
              path: [:nodes, name, :impl],
              code: :unknown_impl,
              message: "predictor module #{inspect(impl)} is not loaded",
              suggestion: nil
            }
          ]

        not predictor_module?(impl) ->
          [
            %{
              path: [:nodes, name, :impl],
              code: :unknown_impl,
              message:
                "module #{inspect(impl)} is not a Dsxir.Predictor: does not export forward/4",
              suggestion: nil
            }
          ]

        true ->
          []
      end
    end)
  end

  defp predictor_module?(mod) do
    function_exported?(mod, :forward, 4)
  end

  defp check_signatures(%RuntimeProgram{nodes: nodes}) do
    Enum.flat_map(nodes, fn %RPNode{name: name, signature: sig} ->
      cond do
        match?(%Compiled{}, sig) ->
          []

        is_atom(sig) and Code.ensure_loaded?(sig) and signature_module?(sig) ->
          []

        is_atom(sig) ->
          [
            %{
              path: [:nodes, name, :signature],
              code: :unknown_signature,
              message:
                "signature module #{inspect(sig)} is not loaded or does not declare a Dsxir.Signature",
              suggestion: nil
            }
          ]

        true ->
          [
            %{
              path: [:nodes, name, :signature],
              code: :unknown_signature,
              message:
                "node signature must be a module atom or %Dsxir.Signature.Compiled{}, got: #{inspect(sig)}",
              suggestion: nil
            }
          ]
      end
    end)
  end

  defp signature_module?(mod) do
    function_exported?(mod, :spark_dsl_config, 0)
  end

  defp check_edge_references(%RuntimeProgram{} = rp) do
    node_map = Map.new(rp.nodes, &{&1.name, &1})
    input_names = MapSet.new(rp.inputs, & &1.name)
    output_names = MapSet.new(rp.outputs, & &1.name)

    rp.edges
    |> Enum.with_index()
    |> Enum.flat_map(fn {edge, idx} ->
      check_endpoint(edge.from, :from, idx, node_map, input_names, output_names) ++
        check_endpoint(edge.to, :to, idx, node_map, input_names, output_names)
    end)
  end

  defp check_endpoint({:program_input, field}, :from, idx, _nodes, inputs, _outputs) do
    if MapSet.member?(inputs, field) do
      []
    else
      [
        %{
          path: [:edges, idx, :from],
          code: :edge_unknown_field,
          message: "program_input field #{inspect(field)} is not declared on the program",
          suggestion: nil
        }
      ]
    end
  end

  defp check_endpoint({:program_output, field}, :to, idx, _nodes, _inputs, outputs) do
    if MapSet.member?(outputs, field) do
      []
    else
      [
        %{
          path: [:edges, idx, :to],
          code: :edge_unknown_field,
          message: "program_output field #{inspect(field)} is not declared on the program",
          suggestion: nil
        }
      ]
    end
  end

  defp check_endpoint({:node, node_name, field}, dir, idx, node_map, _inputs, _outputs) do
    case Map.fetch(node_map, node_name) do
      :error ->
        [
          %{
            path: [:edges, idx, dir],
            code: :edge_unknown_node,
            message: "edge references unknown node #{inspect(node_name)}",
            suggestion: nil
          }
        ]

      {:ok, node} ->
        check_endpoint_field(node, field, dir, idx)
    end
  end

  defp check_endpoint({:const, _value}, :from, _idx, _nodes, _inputs, _outputs), do: []

  defp check_endpoint(other, dir, idx, _nodes, _inputs, _outputs) do
    [
      %{
        path: [:edges, idx, dir],
        code: :edge_unknown_node,
        message: "invalid edge #{dir} endpoint: #{inspect(other)}",
        suggestion: nil
      }
    ]
  end

  defp check_endpoint_field(%RPNode{} = node, field, :from, idx) do
    if signature_has_field?(node.signature, field, :output) do
      []
    else
      [
        %{
          path: [:edges, idx, :from],
          code: :edge_unknown_field,
          message: "node #{inspect(node.name)} has no output field #{inspect(field)}",
          suggestion: nil
        }
      ]
    end
  end

  defp check_endpoint_field(%RPNode{} = node, field, :to, idx) do
    if signature_has_field?(node.signature, field, :input) do
      []
    else
      [
        %{
          path: [:edges, idx, :to],
          code: :edge_unknown_field,
          message: "node #{inspect(node.name)} has no input field #{inspect(field)}",
          suggestion: nil
        }
      ]
    end
  end

  defp signature_has_field?(sig, field, kind) do
    sig
    |> signature_fields_safe(kind)
    |> Enum.any?(&(&1.name == field))
  rescue
    _ -> false
  end

  defp signature_fields_safe(sig, :input), do: Runtime.inputs(sig)
  defp signature_fields_safe(sig, :output), do: Runtime.outputs(sig)

  defp check_program_output_reachability(%RuntimeProgram{outputs: outputs, edges: edges}) do
    reached =
      for %Edge{to: {:program_output, name}} <- edges, into: MapSet.new() do
        name
      end

    Enum.flat_map(outputs, fn %FieldSpec{name: name} ->
      if MapSet.member?(reached, name) do
        []
      else
        [
          %{
            path: [:outputs, name],
            code: :program_output_unreachable,
            message: "program output #{inspect(name)} has no inbound edge",
            suggestion: nil
          }
        ]
      end
    end)
  end

  defp check_dag_acyclic(%RuntimeProgram{} = rp) do
    {graph, nodes} = build_node_graph(rp)

    case kahn_cycle_nodes(graph, nodes) do
      [] ->
        []

      cyclic ->
        scc = Enum.sort(cyclic)

        [
          %{
            path: [:nodes],
            code: :cycle,
            message: "cycle detected among nodes #{inspect(scc)}",
            scc: scc,
            suggestion: nil
          }
        ]
    end
  end

  defp build_node_graph(%RuntimeProgram{nodes: nodes, edges: edges}) do
    names = MapSet.new(nodes, & &1.name)

    graph =
      Enum.reduce(edges, %{}, fn
        %Edge{from: {:node, src, _}, to: {:node, dst, _}}, acc ->
          if MapSet.member?(names, src) and MapSet.member?(names, dst) do
            Map.update(acc, src, MapSet.new([dst]), &MapSet.put(&1, dst))
          else
            acc
          end

        _, acc ->
          acc
      end)

    {graph, MapSet.to_list(names)}
  end

  defp kahn_cycle_nodes(graph, nodes) do
    in_degree = compute_in_degree(graph, nodes)

    {removed, _} =
      Stream.iterate(:start, fn _ -> :step end)
      |> Enum.reduce_while({MapSet.new(), in_degree}, fn _, acc -> kahn_step(acc, graph) end)

    Enum.reject(nodes, &MapSet.member?(removed, &1))
  end

  defp compute_in_degree(graph, nodes) do
    base = Map.new(nodes, &{&1, 0})

    Enum.reduce(graph, base, fn {_src, dsts}, acc ->
      Enum.reduce(dsts, acc, fn d, a -> Map.update(a, d, 1, &(&1 + 1)) end)
    end)
  end

  defp kahn_step({seen, deg}, graph) do
    zero = for {n, 0} <- deg, not MapSet.member?(seen, n), do: n

    case zero do
      [] -> {:halt, {seen, deg}}
      ns -> {:cont, {add_to_set(seen, ns), decrement_children(deg, ns, graph)}}
    end
  end

  defp add_to_set(set, items), do: Enum.reduce(items, set, &MapSet.put(&2, &1))

  defp decrement_children(deg, parents, graph) do
    Enum.reduce(parents, deg, fn n, acc ->
      graph
      |> Map.get(n, MapSet.new())
      |> Enum.reduce(acc, fn d, a -> Map.update(a, d, 0, &(&1 - 1)) end)
    end)
  end

  defp check_dangling_required_inputs(%RuntimeProgram{nodes: nodes, edges: edges}) do
    wired = wired_inputs(edges)
    Enum.flat_map(nodes, &dangling_inputs_for(&1, wired))
  rescue
    _ -> []
  end

  defp wired_inputs(edges) do
    for %Edge{to: {:node, n, f}, kind: :required} <- edges, into: MapSet.new() do
      {n, f}
    end
  end

  defp dangling_inputs_for(%RPNode{} = node, wired) do
    node.signature
    |> signature_fields_safe(:input)
    |> Enum.flat_map(&dangling_input_error(node, &1, wired))
  end

  defp dangling_input_error(%RPNode{name: name}, field, wired) do
    if MapSet.member?(wired, {name, field.name}) do
      []
    else
      [
        %{
          path: [:nodes, name, :inputs, field.name],
          code: :dangling_required_input,
          message:
            "node #{inspect(name)} required input #{inspect(field.name)} has no inbound edge",
          suggestion: nil
        }
      ]
    end
  end

  # ---- Phase 2 ----------------------------------------------------------

  defp phase2_guards(%RuntimeProgram{} = rp) do
    topo_order = topo_order(rp)
    upstream = upstream_map(rp, topo_order)

    {nodes, errors} =
      Enum.map_reduce(rp.nodes, [], fn node, errs ->
        case check_node_guard(node, rp, upstream) do
          {:ok, updated_node} -> {updated_node, errs}
          {:keep, err} -> {node, [err | errs]}
        end
      end)

    {%{rp | nodes: nodes}, Enum.reverse(errors)}
  end

  defp check_node_guard(%RPNode{guard: nil} = node, _rp, _upstream), do: {:ok, node}

  defp check_node_guard(%RPNode{guard: %Predicate.Source{source: src} = ps} = node, rp, upstream) do
    case Predicate.parse(src) do
      {:error, e} -> {:keep, parse_error(node.name, e)}
      {:ok, ast} -> attach_or_type_error(node, ps, ast, rp, upstream)
    end
  end

  defp attach_or_type_error(node, ps, ast, rp, upstream) do
    local_env = local_env_for(node.name, rp, upstream)

    case Predicate.type_check(ast, local_env) do
      :ok -> {:ok, %{node | guard: Predicate.Source.attach_ast(ps, ast)}}
      {:error, e} -> {:keep, type_error(node.name, e)}
    end
  end

  defp parse_error(node_name, e) do
    %{
      path: [:nodes, node_name, :guard],
      code: :predicate_parse_error,
      message: e.message,
      line: Map.get(e, :line),
      col: Map.get(e, :col),
      suggestion: nil
    }
  end

  defp type_error(node_name, e) do
    %{
      path: [:nodes, node_name, :guard],
      code: :predicate_type_error,
      message: "guard failed type check: #{inspect(e)}",
      expected: Map.get(e, :expected),
      got: Map.get(e, :got),
      suggestion: nil
    }
  end

  defp topo_order(%RuntimeProgram{} = rp) do
    {graph, nodes} = build_node_graph(rp)
    in_degree = compute_in_degree(graph, nodes)

    {order, _} =
      Stream.iterate(:start, fn _ -> :step end)
      |> Enum.reduce_while({[], in_degree}, fn _, acc -> topo_step(acc, graph) end)

    order
  end

  defp topo_step({order, deg}, graph) do
    zero_nodes = for {n, 0} <- deg, do: n

    case zero_nodes do
      [] ->
        {:halt, {order, deg}}

      [n | _] ->
        children = graph |> Map.get(n, MapSet.new()) |> MapSet.to_list()

        new_deg =
          children
          |> Enum.reduce(deg, fn d, acc -> Map.update(acc, d, 0, &(&1 - 1)) end)
          |> Map.put(n, -1)

        {:cont, {order ++ [n], new_deg}}
    end
  end

  defp upstream_map(%RuntimeProgram{} = rp, topo) do
    name_index = Map.new(Enum.with_index(topo))
    node_by_name = Map.new(rp.nodes, &{&1.name, &1})
    predecessors = build_predecessors(rp.edges)

    for {name, _idx} <- name_index, into: %{} do
      preds = upstream_predecessors(predecessors, name, name_index)
      {name, upstream_signatures(preds, node_by_name)}
    end
  end

  defp build_predecessors(edges) do
    Enum.reduce(edges, %{}, fn
      %Edge{from: {:node, src, _}, to: {:node, dst, _}}, acc ->
        Map.update(acc, dst, MapSet.new([src]), &MapSet.put(&1, src))

      _, acc ->
        acc
    end)
  end

  defp upstream_predecessors(predecessors, name, name_index) do
    predecessors
    |> Map.get(name, MapSet.new())
    |> Enum.filter(fn p ->
      Map.has_key?(name_index, p) and name_index[p] < name_index[name]
    end)
  end

  defp upstream_signatures(preds, node_by_name) do
    Enum.flat_map(preds, fn p ->
      case Map.get(node_by_name, p) do
        nil -> []
        pn -> [{p, pn.signature}]
      end
    end)
  end

  defp local_env_for(name, %RuntimeProgram{} = rp, upstream) do
    pi_env =
      Map.new(rp.inputs, fn %FieldSpec{name: f, type: t} -> {f, normalize_type(t)} end)

    upstream
    |> Map.get(name, [])
    |> Enum.reduce(%{program_input: pi_env}, fn {ns, sig}, acc ->
      fields =
        sig
        |> safe_outputs()
        |> Map.new(fn field -> {field.name, normalize_type(field.type)} end)

      Map.put(acc, ns, fields)
    end)
  end

  defp safe_outputs(sig) do
    Runtime.outputs(sig)
  rescue
    _ -> []
  end

  # ---- Phase 3 ----------------------------------------------------------

  defp phase3_types(%RuntimeProgram{} = rp) do
    node_map = Map.new(rp.nodes, &{&1.name, &1})
    input_types = field_type_map(rp.inputs)
    output_types = field_type_map(rp.outputs)

    rp.edges
    |> Enum.with_index()
    |> Enum.flat_map(&check_edge_type(&1, node_map, input_types, output_types))
  end

  defp field_type_map(field_specs) do
    Map.new(field_specs, fn %FieldSpec{name: n, type: t} -> {n, normalize_type(t)} end)
  end

  defp check_edge_type({edge, idx}, node_map, input_types, output_types) do
    with {:ok, ptype} <- producer_type(edge.from, node_map, input_types),
         {:ok, ctype} <- consumer_type(edge.to, node_map, output_types),
         false <- compatible?(ptype, ctype) do
      [edge_type_mismatch(idx, ptype, ctype)]
    else
      _ -> []
    end
  end

  defp edge_type_mismatch(idx, ptype, ctype) do
    %{
      path: [:edges, idx],
      code: :edge_type_mismatch,
      message: "edge #{idx} type mismatch: producer=#{inspect(ptype)} consumer=#{inspect(ctype)}",
      expected: ctype,
      got: ptype,
      edge_index: idx,
      suggestion: nil
    }
  end

  defp producer_type({:program_input, f}, _nodes, inputs) do
    case Map.fetch(inputs, f) do
      {:ok, t} -> {:ok, t}
      :error -> :skip
    end
  end

  defp producer_type({:node, name, field}, node_map, _inputs) do
    case Map.fetch(node_map, name) do
      {:ok, node} -> field_type(node.signature, field, :output)
      :error -> :skip
    end
  end

  defp producer_type({:const, _value}, _nodes, _inputs), do: {:ok, :any}

  defp consumer_type({:program_output, f}, _nodes, outputs) do
    case Map.fetch(outputs, f) do
      {:ok, t} -> {:ok, t}
      :error -> :skip
    end
  end

  defp consumer_type({:node, name, field}, node_map, _outputs) do
    case Map.fetch(node_map, name) do
      {:ok, node} -> field_type(node.signature, field, :input)
      :error -> :skip
    end
  end

  defp field_type(sig, field, kind) do
    sig
    |> signature_fields_safe(kind)
    |> Enum.find(&(&1.name == field))
    |> case do
      nil -> :skip
      f -> {:ok, normalize_type(f.type)}
    end
  rescue
    _ -> :skip
  end

  defp compatible?(a, b), do: a == b or a == :any or b == :any

  defp normalize_type("str"), do: :string
  defp normalize_type("int"), do: :integer
  defp normalize_type("float"), do: :float
  defp normalize_type("bool"), do: :boolean
  defp normalize_type("dict"), do: :map
  defp normalize_type(:string), do: :string
  defp normalize_type(:integer), do: :integer
  defp normalize_type(:float), do: :float
  defp normalize_type(:boolean), do: :boolean
  defp normalize_type(:atom), do: :atom
  defp normalize_type({:list, inner}), do: {:list, normalize_type(inner)}

  defp normalize_type(<<"list[", _::binary>> = t) do
    case String.split(t, ["list[", "]"], trim: true) do
      [inner] -> {:list, normalize_type(inner)}
      _ -> :any
    end
  end

  defp normalize_type(other) when is_atom(other), do: other
  defp normalize_type(other) when is_binary(other), do: :any
  defp normalize_type(_), do: :any
end
