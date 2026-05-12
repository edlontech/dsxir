defmodule Dsxir.Optimizer.LabeledFewShotTest do
  use ExUnit.Case, async: true

  alias Dsxir.Optimizer.LabeledFewShot
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

  defp ex(q, a), do: Dsxir.Example.new(%{q: q, a: a}, input_keys: [:q])

  defp metric(_e, _p, _t), do: 1.0

  test "empty trainset returns {:error, Invalid.Trainset{reason: :empty}}" do
    assert {:error, %Dsxir.Errors.Invalid.Trainset{reason: :empty, example: nil}} =
             LabeledFewShot.compile(Program.new(Prog), [], &metric/3, [])
  end

  test "non-Example entries return {:error, Invalid.Trainset{reason: :not_an_example, example}}" do
    assert {:error,
            %Dsxir.Errors.Invalid.Trainset{
              reason: :not_an_example,
              example: %{not: :an_example}
            }} =
             LabeledFewShot.compile(
               Program.new(Prog),
               [%{not: :an_example}],
               &metric/3,
               []
             )
  end

  test "slots demos into every predictor's state, capped at max_labeled_demos" do
    trainset = Enum.map(1..10, &ex("q#{&1}", "a#{&1}"))

    {:ok, compiled, stats} =
      LabeledFewShot.compile(Program.new(Prog), trainset, &metric/3, max_labeled_demos: 5)

    assert stats.labeled_demos == 5
    assert stats.predictor_count == 1
    assert stats.deterministic == false

    state = Program.get_state(compiled, :answer)
    assert length(state.demos) == 5
  end

  test "max_labeled_demos > length(trainset) clamps to trainset size" do
    trainset = Enum.map(1..3, &ex("q#{&1}", "a#{&1}"))

    {:ok, _compiled, stats} =
      LabeledFewShot.compile(Program.new(Prog), trainset, &metric/3, max_labeled_demos: 16)

    assert stats.labeled_demos == 3
  end

  test ":deterministic produces a stable selection across runs" do
    trainset = Enum.map(1..30, &ex("q#{&1}", "a#{&1}"))

    {:ok, c1, _} =
      LabeledFewShot.compile(Program.new(Prog), trainset, &metric/3,
        max_labeled_demos: 5,
        deterministic: true
      )

    {:ok, c2, _} =
      LabeledFewShot.compile(Program.new(Prog), trainset, &metric/3,
        max_labeled_demos: 5,
        deterministic: true
      )

    assert Program.get_state(c1, :answer).demos == Program.get_state(c2, :answer).demos
  end

  test "stamps metadata.compiled_with, score, trainset_hash" do
    trainset = [ex("q1", "a1")]

    {:ok, compiled, _stats} =
      LabeledFewShot.compile(Program.new(Prog), trainset, &metric/3, [])

    assert compiled.metadata.compiled_with == LabeledFewShot
    assert compiled.metadata.score == nil
    assert is_binary(compiled.metadata.trainset_hash)
    assert byte_size(compiled.metadata.trainset_hash) == 64
  end
end
