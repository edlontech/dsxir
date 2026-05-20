defmodule Dsxir.RuntimeProgram.Executor do
  @moduledoc """
  Sequential topological DAG walk with skip cascading and an `on_skip` policy.

  The executor is a pure function over a `%Dsxir.RuntimeProgram{}`, a host
  `%Dsxir.Program{}`, and an inputs map. Per design, concurrency is deferred:
  nodes execute in a single deterministic topological order produced by
  `Dsxir.RuntimeProgram.Topological.sort/2`.

  Per node:

    1. If any inbound `:required` edge originates from a previously-skipped
       node, this node is skipped and a `[:dsxir, :runtime_program, :skipped]`
       event is emitted with `reason: :upstream_required_skipped`.
    2. Otherwise the (optional) guard predicate is evaluated against an env
       built only from upstream-node outputs and the program inputs. A
       `{:ok, false}` skips the node with `reason: :guard_false`. A runtime
       evaluator error raises `Dsxir.Errors.Runtime.PredicateError`.
    3. Inputs are resolved from inbound edges. Edges whose source was skipped
       and whose kind is `:optional` substitute `nil` and mark the node's
       invocation as `degraded` (forwarded to `Dsxir.Module.Runtime.call/4`).
    4. After all nodes run, program outputs are projected from the env. If
       any output's chain was skipped, the `on_skip` policy decides whether
       to raise `Dsxir.Errors.Runtime.SkippedOutputs`, return
       `{:partial, %Prediction{}}`, or surface a `%Prediction{}` with
       nil-valued fields and a non-`nil` `:skipped` list.

  Iron Law: the executor is stateless aside from a local `%ExecState{}`
  accumulator. Plain functions only — no GenServer, no Task.
  """

  alias Dsxir.Errors.Framework
  alias Dsxir.Errors.Runtime
  alias Dsxir.Predicate
  alias Dsxir.Prediction
  alias Dsxir.Program
  alias Dsxir.RuntimeProgram
  alias Dsxir.RuntimeProgram.Edge
  alias Dsxir.RuntimeProgram.Node, as: RPNode
  alias Dsxir.RuntimeProgram.Topological
  alias Dsxir.Telemetry

  defmodule ExecState do
    @moduledoc false
    defstruct program: nil,
              rp: nil,
              inputs: %{},
              outputs: %{},
              skipped: MapSet.new(),
              degraded: MapSet.new()

    @type t :: %__MODULE__{
            program: Dsxir.Program.t() | nil,
            rp: Dsxir.RuntimeProgram.t() | nil,
            inputs: map(),
            outputs: map(),
            skipped: MapSet.t(atom()),
            degraded: MapSet.t(atom())
          }
  end

  @type on_skip :: :raise | :tagged_tuple | nil

  @doc """
  Execute `rp` against host `prog` with `inputs`. See this module's
  `@moduledoc` for the per-node algorithm and the `on_skip` policy.

  Supported opts:

    * `:on_skip` — `:raise` (default), `:tagged_tuple`, or `nil`.
  """
  @spec execute(RuntimeProgram.t(), Program.t(), map(), keyword()) ::
          {Program.t(), Prediction.t()}
          | {Program.t(), {:partial, Prediction.t()}}
  def execute(%RuntimeProgram{} = rp, %Program{} = prog, inputs, opts \\ [])
      when is_map(inputs) and is_list(opts) do
    on_skip = Keyword.get(opts, :on_skip, :raise)

    unless on_skip in [:raise, :tagged_tuple, nil] do
      raise ArgumentError,
            "invalid on_skip option: #{inspect(on_skip)}; expected :raise, :tagged_tuple, or nil"
    end

    case Topological.sort(rp.nodes, rp.edges) do
      {:ok, order} ->
        by_name = Map.new(rp.nodes, fn n -> {n.name, n} end)
        state = %ExecState{program: prog, rp: rp, inputs: inputs, outputs: %{}}

        final = Enum.reduce(order, state, fn name, st -> visit(by_name[name], st) end)
        prediction = project_outputs(final)
        apply_on_skip(final, prediction, on_skip)

      {:error, {:cycle, nodes}} ->
        raise %Framework.CycleDetected{nodes: nodes}
    end
  end

  defp visit(%RPNode{} = node, %ExecState{} = st) do
    required_deps = required_dep_nodes(node, st.rp)
    optional_deps = optional_dep_nodes(node, st.rp)

    if Enum.any?(required_deps, &MapSet.member?(st.skipped, &1)) do
      emit_skip(node, :upstream_required_skipped, st.rp)
      %{st | skipped: MapSet.put(st.skipped, node.name)}
    else
      eval_and_run(node, st, optional_deps)
    end
  end

  defp eval_and_run(%RPNode{} = node, %ExecState{} = st, optional_deps) do
    env = build_predicate_env(node, st)

    case eval_guard(node.guard, env) do
      :no_guard ->
        run(node, st, any_optional_skipped?(optional_deps, st))

      {:ok, true} ->
        run(node, st, any_optional_skipped?(optional_deps, st))

      {:ok, false} ->
        emit_skip(node, :guard_false, st.rp)
        %{st | skipped: MapSet.put(st.skipped, node.name)}

      {:error, reason} ->
        raise %Runtime.PredicateError{
          node: node.name,
          ast: guard_ast(node.guard),
          env: env,
          reason: reason
        }
    end
  end

  defp any_optional_skipped?(optional_deps, %ExecState{skipped: skipped}),
    do: Enum.any?(optional_deps, &MapSet.member?(skipped, &1))

  defp run(%RPNode{} = node, %ExecState{} = st, degraded?) do
    inputs = resolved_inputs(node, st)

    {new_prog, prediction} =
      Dsxir.Module.Runtime.call(st.program, node.name, inputs, degraded: degraded?)

    outputs = Map.put(st.outputs, node.name, prediction.fields)

    %{
      st
      | program: new_prog,
        outputs: outputs,
        degraded: maybe_mark_degraded(st.degraded, node.name, degraded?)
    }
  end

  defp maybe_mark_degraded(set, _name, false), do: set
  defp maybe_mark_degraded(set, name, true), do: MapSet.put(set, name)

  defp eval_guard(nil, _env), do: :no_guard

  defp eval_guard(%Predicate.Source{ast: %Predicate.AST{} = ast}, env),
    do: Predicate.eval(ast, env)

  defp guard_ast(%Predicate.Source{ast: ast}), do: ast

  defp emit_skip(%RPNode{name: name}, reason, %RuntimeProgram{} = rp) do
    Telemetry.emit(
      [:dsxir, :runtime_program, :skipped],
      %{},
      %{node: name, reason: reason, program_id: rp.id, program_version: rp.version}
    )
  end

  defp required_dep_nodes(%RPNode{name: name}, %RuntimeProgram{edges: edges}) do
    for %Edge{from: {:node, src, _}, to: {:node, ^name, _}, kind: :required} <- edges,
        uniq: true,
        do: src
  end

  defp optional_dep_nodes(%RPNode{name: name}, %RuntimeProgram{edges: edges}) do
    for %Edge{from: {:node, src, _}, to: {:node, ^name, _}, kind: :optional} <- edges,
        uniq: true,
        do: src
  end

  defp build_predicate_env(%RPNode{name: name}, %ExecState{} = st) do
    upstream_nodes = upstream_node_names(name, st.rp)

    upstream_env =
      upstream_nodes
      |> Enum.reduce(%{}, fn src, acc ->
        case Map.fetch(st.outputs, src) do
          {:ok, fields} -> Map.put(acc, src, fields)
          :error -> acc
        end
      end)

    Map.put(upstream_env, :program_input, st.inputs)
  end

  defp upstream_node_names(name, %RuntimeProgram{edges: edges}) do
    for %Edge{from: {:node, src, _}, to: {:node, ^name, _}} <- edges, uniq: true, do: src
  end

  defp resolved_inputs(%RPNode{name: name}, %ExecState{} = st) do
    for %Edge{to: {:node, ^name, field}} = edge <- st.rp.edges, into: %{} do
      {field, resolve_edge_value(edge, name, st)}
    end
  end

  defp resolve_edge_value(%Edge{from: {:program_input, f}}, node_name, %ExecState{} = st) do
    case Map.fetch(st.inputs, f) do
      {:ok, value} -> value
      :error -> raise %Framework.MissingInput{node: node_name, field: f}
    end
  end

  defp resolve_edge_value(
         %Edge{from: {:node, src, field}, kind: :optional},
         _node_name,
         %ExecState{} = st
       ) do
    if MapSet.member?(st.skipped, src), do: nil, else: get_in(st.outputs, [src, field])
  end

  defp resolve_edge_value(
         %Edge{from: {:node, src, field}, kind: :required},
         _node_name,
         %ExecState{} = st
       ) do
    get_in(st.outputs, [src, field])
  end

  defp resolve_edge_value(%Edge{from: {:const, value}}, _node_name, _st), do: value

  defp project_outputs(%ExecState{rp: %RuntimeProgram{outputs: outputs}} = st) do
    {fields, skipped_acc} = Enum.reduce(outputs, {%{}, []}, &project_one(&1, &2, st))
    skipped = if skipped_acc == [], do: nil, else: Enum.reverse(skipped_acc)
    Prediction.new(fields, skipped: skipped)
  end

  defp project_one(spec, {acc, skipped_acc}, %ExecState{} = st) do
    case find_edge_to_output(st.rp, spec.name) do
      {:ok, edge} -> project_from_edge(spec, edge, acc, skipped_acc, st)
      :error -> raise %Framework.MissingInput{node: :program_output, field: spec.name}
    end
  end

  defp project_from_edge(
         spec,
         %Edge{from: {:node, src, field}},
         acc,
         skipped_acc,
         %ExecState{} = st
       ) do
    if MapSet.member?(st.skipped, src) do
      {Map.put(acc, spec.name, nil), [spec.name | skipped_acc]}
    else
      {Map.put(acc, spec.name, get_in(st.outputs, [src, field])), skipped_acc}
    end
  end

  defp project_from_edge(
         spec,
         %Edge{from: {:program_input, f}},
         acc,
         skipped_acc,
         %ExecState{} = st
       ),
       do: {Map.put(acc, spec.name, Map.get(st.inputs, f)), skipped_acc}

  defp project_from_edge(spec, %Edge{from: {:const, value}}, acc, skipped_acc, _st),
    do: {Map.put(acc, spec.name, value), skipped_acc}

  defp find_edge_to_output(%RuntimeProgram{edges: edges}, output_name) do
    Enum.find_value(edges, :error, fn
      %Edge{to: {:program_output, ^output_name}} = edge -> {:ok, edge}
      _ -> nil
    end)
  end

  defp apply_on_skip(%ExecState{} = st, %Prediction{skipped: nil} = pred, _on_skip),
    do: {st.program, pred}

  defp apply_on_skip(_st, %Prediction{skipped: skipped} = pred, :raise) do
    raise %Runtime.SkippedOutputs{skipped: skipped, prediction: pred}
  end

  defp apply_on_skip(%ExecState{} = st, %Prediction{} = pred, :tagged_tuple),
    do: {st.program, {:partial, pred}}

  defp apply_on_skip(%ExecState{} = st, %Prediction{} = pred, nil),
    do: {st.program, pred}
end
