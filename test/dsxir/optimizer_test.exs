defmodule Dsxir.OptimizerTest do
  use ExUnit.Case, async: true

  alias Dsxir.Errors.Invalid.Trainset
  alias Dsxir.Optimizer
  alias Dsxir.Program

  defmodule Sig do
    use Dsxir.Signature

    signature do
      input(:q, :string)
      output(:a, :string)
    end
  end

  defmodule Prog do
    use Dsxir.Module

    predictor(:answer, Dsxir.Predictor.Predict, signature: Sig)

    def forward(p, inputs), do: call(p, :answer, inputs)
  end

  defmodule StubOptimizer do
    @behaviour Dsxir.Optimizer

    @impl true
    def compile(%Program{} = student, trainset, metric, opts)
        when is_list(trainset) and is_function(metric, 3) and is_list(opts) do
      compiled = %{
        student
        | metadata: Map.merge(student.metadata, %{compiled_with: __MODULE__, score: 0.5})
      }

      {:ok, compiled, %{trainset_size: length(trainset), custom_key: :extra}}
    end
  end

  defmodule EmptyOptimizer do
    @behaviour Dsxir.Optimizer

    @impl true
    def compile(%Program{}, [], _metric, _opts) do
      {:error, %Trainset{reason: :empty, example: nil}}
    end

    def compile(%Program{} = student, trainset, _metric, _opts)
        when is_list(trainset) do
      {:ok, student, %{}}
    end
  end

  defp ex(q, a), do: Dsxir.Example.new(%{q: q, a: a}, input_keys: [:q])

  defp metric(_e, _p, _t), do: 1.0

  describe "compile/5 dispatcher" do
    test "calls the named impl and returns its {:ok, program, stats} tuple" do
      student = Program.new(Prog)
      trainset = [ex("q", "a")]

      assert {:ok, %Program{} = compiled, %{trainset_size: 1}} =
               Optimizer.compile(StubOptimizer, student, trainset, &metric/3, [])

      assert compiled.metadata.compiled_with == StubOptimizer
      assert compiled.metadata.score == 0.5
    end

    test "stats map is open: optimizers may add custom keys" do
      student = Program.new(Prog)
      trainset = [ex("q", "a"), ex("q2", "a2")]

      assert {:ok, _prog, stats} =
               Optimizer.compile(StubOptimizer, student, trainset, &metric/3, foo: :bar)

      assert is_map(stats)
      assert Map.get(stats, :custom_key) == :extra
      assert Map.get(stats, :trainset_size) == 2
    end

    test "{:error, splode} contract on failure" do
      student = Program.new(Prog)

      assert {:error, %Trainset{reason: :empty, example: nil}} =
               Optimizer.compile(EmptyOptimizer, student, [], &metric/3, [])
    end
  end
end
