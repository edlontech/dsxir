defmodule Dsxir.Test.Fixtures.RuntimePrograms do
  @moduledoc """
  Helpers that produce `%Dsxir.RuntimeProgram{}` baselines and apply
  targeted mutations for the Validator test suite.
  """

  alias Dsxir.RuntimeProgram
  alias Dsxir.RuntimeProgram.Edge
  alias Dsxir.RuntimeProgram.FieldSpec
  alias Dsxir.RuntimeProgram.Node
  alias Dsxir.Test.Fixtures.AnswerQuestion
  alias Dsxir.Test.Fixtures.QA
  alias Dsxir.Test.Fixtures.RuntimeProgramPayloads
  alias Dsxir.Test.Fixtures.ScriptedLM

  @doc "A parsed, validated-by-design baseline program."
  @spec minimal_valid() :: RuntimeProgram.t()
  def minimal_valid do
    {:ok, rp} = RuntimeProgram.from_map(RuntimeProgramPayloads.valid())
    rp
  end

  @doc """
  Two-step linear chain `step1 -> step2`, both predicting through the
  `ScriptedLM` fixture against `AnswerQuestion`. Wires
  `program_input.question -> step1 -> step2 -> program_output.answer`.
  """
  @spec linear_chain() :: RuntimeProgram.t()
  def linear_chain do
    rp = %RuntimeProgram{
      id: "test/linear_chain",
      version: <<0::256>>,
      inputs: [%FieldSpec{name: :question, type: :string}],
      outputs: [%FieldSpec{name: :answer, type: :string}],
      nodes: [
        %Node{name: :step1, impl: ScriptedLM, signature: AnswerQuestion},
        %Node{name: :step2, impl: ScriptedLM, signature: AnswerQuestion}
      ],
      edges: [
        %Edge{from: {:program_input, :question}, to: {:node, :step1, :question}},
        %Edge{from: {:node, :step1, :answer}, to: {:node, :step2, :question}},
        %Edge{from: {:node, :step2, :answer}, to: {:program_output, :answer}}
      ]
    }

    %{rp | version: RuntimeProgram.version!(rp)}
  end

  @doc """
  Two-step chain where `step2`'s guard always evaluates to `false` and the
  edge `step2.answer -> program_output.answer` is `:required`. Used to exercise
  `Program.forward/3` with `on_skip: :raise`.
  """
  @spec with_guard_false_on_required_output() :: RuntimeProgram.t()
  def with_guard_false_on_required_output do
    {:ok, ast} = Dsxir.Predicate.parse("step1.answer == \"__never_matches__\"")
    guard = %Dsxir.Predicate.Source{source: ast.source, ast: ast}

    rp = %RuntimeProgram{
      id: "test/guard_false_required",
      version: <<0::256>>,
      inputs: [%FieldSpec{name: :question, type: :string}],
      outputs: [%FieldSpec{name: :answer, type: :string}],
      nodes: [
        %Node{name: :step1, impl: ScriptedLM, signature: AnswerQuestion},
        %Node{name: :step2, impl: ScriptedLM, signature: AnswerQuestion, guard: guard}
      ],
      edges: [
        %Edge{from: {:program_input, :question}, to: {:node, :step1, :question}},
        %Edge{from: {:node, :step1, :answer}, to: {:node, :step2, :question}},
        %Edge{
          from: {:node, :step2, :answer},
          to: {:program_output, :answer},
          kind: :required
        }
      ]
    }

    %{rp | version: RuntimeProgram.version!(rp)}
  end

  @doc """
  Single-node runtime program that mirrors `Dsxir.Test.Fixtures.QAScripted`'s
  shape: one node `:answer` running through `ScriptedLM` against `QA.Sig`
  (`q -> a`). Drives the parameterized Source contract suite so both module
  and runtime sources exercise an identical scenario.
  """
  @spec equivalent_to_qa() :: RuntimeProgram.t()
  def equivalent_to_qa do
    rp = %RuntimeProgram{
      id: "test/equivalent_to_qa",
      version: <<0::256>>,
      inputs: [%FieldSpec{name: :q, type: :string}],
      outputs: [%FieldSpec{name: :a, type: :string}],
      nodes: [
        %Node{name: :answer, impl: ScriptedLM, signature: QA.Sig}
      ],
      edges: [
        %Edge{from: {:program_input, :q}, to: {:node, :answer, :q}},
        %Edge{from: {:node, :answer, :a}, to: {:program_output, :a}}
      ]
    }

    %{rp | version: RuntimeProgram.version!(rp)}
  end

  @doc """
  Live-LM variant of `linear_chain/0`: a single-node runtime program with
  `:answer` over `AnswerQuestion`, routed through `Dsxir.Predictor.Predict`
  so the configured LM in scope is actually invoked. Suitable for
  `@tag :live_lm` end-to-end tests against Sycophant.
  """
  @spec linear_chain_live() :: RuntimeProgram.t()
  def linear_chain_live do
    rp = %RuntimeProgram{
      id: "test/linear_chain_live",
      version: <<0::256>>,
      inputs: [%FieldSpec{name: :question, type: :string}],
      outputs: [%FieldSpec{name: :answer, type: :string}],
      nodes: [
        %Node{name: :answer, impl: Dsxir.Predictor.Predict, signature: AnswerQuestion}
      ],
      edges: [
        %Edge{from: {:program_input, :question}, to: {:node, :answer, :question}},
        %Edge{from: {:node, :answer, :answer}, to: {:program_output, :answer}}
      ]
    }

    %{rp | version: RuntimeProgram.version!(rp)}
  end

  @doc "Duplicate the named node so it appears twice."
  @spec dup_node(RuntimeProgram.t(), atom()) :: RuntimeProgram.t()
  def dup_node(%RuntimeProgram{nodes: nodes} = rp, name) do
    case Enum.find(nodes, &(&1.name == name)) do
      nil -> rp
      node -> %{rp | nodes: nodes ++ [node]}
    end
  end

  @doc "Replace edge at `index`'s `to:` endpoint with a reference to a missing node."
  @spec break_edge_target(RuntimeProgram.t(), non_neg_integer()) :: RuntimeProgram.t()
  def break_edge_target(%RuntimeProgram{edges: edges} = rp, index) do
    edges =
      List.update_at(edges, index, fn %Edge{} = edge ->
        %{edge | to: {:node, :__never_exists__, :__never_field__}}
      end)

    %{rp | edges: edges}
  end

  @doc "Set the guard on `node_name` to a string whose parser will fail."
  @spec break_guard_parse(RuntimeProgram.t(), atom()) :: RuntimeProgram.t()
  def break_guard_parse(%RuntimeProgram{nodes: nodes} = rp, node_name) do
    nodes =
      Enum.map(nodes, fn
        %Node{name: ^node_name} = node ->
          %{node | guard: %Dsxir.Predicate.Source{source: ")))) not a predicate"}}

        other ->
          other
      end)

    %{rp | nodes: nodes}
  end

  @doc """
  Diamond-shaped runtime program with an optional fan-in edge.

  Topology:

    * `:extract` (root, no guard) — wired from `program_input.question`.
    * `:route` (guard `input.go == true`) — consumes `:extract.answer`.
    * `:validate` (guard `input.check == true`) — consumes `:extract.answer`.
    * `:merge` — consumes `:route.answer` (`:required`) and `:validate.answer`
      (`:optional`); emits `:merge.answer` as the program output.

  Program inputs are `:question :string`, `:go :boolean`, `:check :boolean`.
  The boolean flags are unused by edges and serve only as guard inputs.
  When `:check` is false but `:go` is true, `:validate` is skipped and the
  optional fan-in into `:merge` substitutes `nil`, marking `:merge`'s trace
  entry as `degraded: true`. When `:go` is false, `:route` is skipped and
  the required input into `:merge` cascades the skip.
  """
  @spec diamond_with_optional_fan_in() :: RuntimeProgram.t()
  def diamond_with_optional_fan_in do
    {:ok, route_ast} = Dsxir.Predicate.parse("input.go == true")
    {:ok, validate_ast} = Dsxir.Predicate.parse("input.check == true")

    route_guard = %Dsxir.Predicate.Source{source: route_ast.source, ast: route_ast}

    validate_guard = %Dsxir.Predicate.Source{
      source: validate_ast.source,
      ast: validate_ast
    }

    rp = %RuntimeProgram{
      id: "test/diamond_optional_fan_in",
      version: <<0::256>>,
      inputs: [
        %FieldSpec{name: :question, type: :string},
        %FieldSpec{name: :go, type: :boolean},
        %FieldSpec{name: :check, type: :boolean}
      ],
      outputs: [%FieldSpec{name: :answer, type: :string}],
      nodes: [
        %Node{name: :extract, impl: ScriptedLM, signature: AnswerQuestion},
        %Node{name: :route, impl: ScriptedLM, signature: AnswerQuestion, guard: route_guard},
        %Node{
          name: :validate,
          impl: ScriptedLM,
          signature: AnswerQuestion,
          guard: validate_guard
        },
        %Node{name: :merge, impl: ScriptedLM, signature: AnswerQuestion}
      ],
      edges: [
        %Edge{from: {:program_input, :question}, to: {:node, :extract, :question}},
        %Edge{from: {:node, :extract, :answer}, to: {:node, :route, :question}},
        %Edge{from: {:node, :extract, :answer}, to: {:node, :validate, :question}},
        %Edge{
          from: {:node, :route, :answer},
          to: {:node, :merge, :question},
          kind: :required
        },
        %Edge{
          from: {:node, :validate, :answer},
          to: {:node, :merge, :question},
          kind: :optional
        },
        %Edge{from: {:node, :merge, :answer}, to: {:program_output, :answer}}
      ]
    }

    %{rp | version: RuntimeProgram.version!(rp)}
  end

  @doc "Set the guard on `node_name` to a syntactically valid predicate that fails type checking."
  @spec break_guard_type(RuntimeProgram.t(), atom()) :: RuntimeProgram.t()
  def break_guard_type(%RuntimeProgram{nodes: nodes} = rp, node_name) do
    nodes =
      Enum.map(nodes, fn
        %Node{name: ^node_name} = node ->
          %{node | guard: %Dsxir.Predicate.Source{source: "length(input.question) > \"abc\""}}

        other ->
          other
      end)

    %{rp | nodes: nodes}
  end
end
