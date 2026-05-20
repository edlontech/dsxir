defmodule Dsxir.Test.Fixtures.RuntimeProgramPayloads do
  @moduledoc """
  Sample JSON-ish payloads for the RuntimeProgram parse and canonical-hash
  tests. The module-atom impl and signature names are existing test fixtures
  so `String.to_existing_atom/1` succeeds.
  """

  @doc """
  A payload that parses AND validates: every edge connects real nodes,
  every required input is wired, the guard parses and type-checks, and
  no cycles exist.
  """
  @spec valid() :: map()
  def valid do
    %{
      "id" => "qa/valid",
      "inputs" => [
        %{"name" => "question", "type" => "str"}
      ],
      "outputs" => [
        %{"name" => "answer", "type" => "str"}
      ],
      "nodes" => [
        %{
          "name" => "qa",
          "impl" => "Elixir.Dsxir.Predictor.Predict",
          "signature" => "Elixir.Dsxir.Test.Fixtures.AnswerQuestion"
        },
        %{
          "name" => "refine",
          "impl" => "Elixir.Dsxir.Predictor.Predict",
          "signature" => "Elixir.Dsxir.Test.Fixtures.AnswerQuestion",
          "guard_source" => "length(input.question) > 0"
        }
      ],
      "edges" => [
        %{
          "from" => ["program_input", "question"],
          "to" => ["node", "qa", "question"],
          "kind" => "required"
        },
        %{
          "from" => ["node", "qa", "answer"],
          "to" => ["node", "refine", "question"],
          "kind" => "required"
        },
        %{
          "from" => ["node", "refine", "answer"],
          "to" => ["program_output", "answer"],
          "kind" => "required"
        }
      ],
      "metadata" => %{"description" => "valid two-stage qa"}
    }
  end

  @spec minimal() :: map()
  def minimal do
    %{
      "id" => "qa/v1",
      "inputs" => [
        %{"name" => "question", "type" => "str"}
      ],
      "outputs" => [
        %{"name" => "answer", "type" => "str"}
      ],
      "nodes" => [
        %{
          "name" => "qa",
          "impl" => "Elixir.Dsxir.Predictor.Predict",
          "signature" => "Elixir.Dsxir.Test.Fixtures.AnswerQuestion"
        },
        %{
          "name" => "refine",
          "impl" => "Elixir.Dsxir.Predictor.Predict",
          "signature" => "Elixir.Dsxir.Test.Fixtures.AnswerQuestion",
          "guard_source" => "len(question) > 0"
        }
      ],
      "edges" => [
        %{
          "from" => ["program_input", "question"],
          "to" => ["node", "qa", "question"],
          "kind" => "required"
        },
        %{
          "from" => ["node", "qa", "answer"],
          "to" => ["program_output", "answer"]
        }
      ],
      "metadata" => %{"description" => "minimal qa"}
    }
  end

  @spec with_inline_signature() :: map()
  def with_inline_signature do
    %{
      "id" => "qa/inline",
      "inputs" => [%{"name" => "question", "type" => "str"}],
      "outputs" => [%{"name" => "answer", "type" => "str"}],
      "nodes" => [
        %{
          "name" => "qa",
          "impl" => "Elixir.Dsxir.Predictor.Predict",
          "signature" => %{
            "instruction" => "Answer briefly.",
            "fields" => [
              %{"name" => "question", "type" => "str", "kind" => "input"},
              %{"name" => "answer", "type" => "str", "kind" => "output"}
            ]
          }
        }
      ],
      "edges" => [
        %{"from" => ["program_input", "question"], "to" => ["node", "qa", "question"]},
        %{"from" => ["node", "qa", "answer"], "to" => ["program_output", "answer"]}
      ],
      "metadata" => %{}
    }
  end
end
