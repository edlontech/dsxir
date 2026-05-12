defmodule Dsxir.Test.Fixtures.QA do
  @moduledoc """
  Small Q -> A fixtures for evaluate / compile / save / load tests.

  Stable across runs: `dataset/0` is deterministic so trainset / holdout / devset
  splits are reproducible.
  """

  defmodule Sig do
    @moduledoc "Answer the question concisely."
    use Dsxir.Signature

    signature do
      input :q, :string
      output :a, :string
    end
  end

  defmodule Prog do
    @moduledoc false
    use Dsxir.Module

    predictor :answer, Dsxir.Predictor.Predict, signature: Sig

    def forward(p, inputs), do: call(p, :answer, inputs)
  end

  defmodule ExtractIntent do
    @moduledoc "Extract the topical category of the question."
    use Dsxir.Signature

    signature do
      input :q, :string
      output :category, :string
    end
  end

  defmodule AnswerWithCategory do
    @moduledoc "Answer the question, given an inferred category."
    use Dsxir.Signature

    signature do
      input :q, :string
      input :category, :string
      output :a, :string
    end
  end

  defmodule TwoStep do
    @moduledoc false
    use Dsxir.Module

    predictor :extract, Dsxir.Predictor.ChainOfThought, signature: ExtractIntent
    predictor :answer, Dsxir.Predictor.Predict, signature: AnswerWithCategory

    def forward(prog, %{q: q}) do
      {prog, ex} = call(prog, :extract, %{q: q})
      {prog, an} = call(prog, :answer, %{q: q, category: ex.fields.category})
      {prog, an}
    end
  end

  @qa_pairs [
    {"What is 2 + 2?", "4"},
    {"Capital of France?", "Paris"},
    {"Author of '1984'?", "George Orwell"},
    {"Largest planet?", "Jupiter"},
    {"Speed of light (km/s)?", "299792"},
    {"Chemical symbol for gold?", "Au"},
    {"Year WWII ended?", "1945"},
    {"Square root of 144?", "12"},
    {"Capital of Japan?", "Tokyo"},
    {"Boiling point of water (C)?", "100"},
    {"First president of the US?", "George Washington"},
    {"Currency of Brazil?", "Real"},
    {"Tallest mountain?", "Mount Everest"},
    {"H2O is...?", "Water"},
    {"Year Apollo 11 landed?", "1969"},
    {"Smallest prime number?", "2"},
    {"Capital of Australia?", "Canberra"},
    {"Author of 'Hamlet'?", "William Shakespeare"},
    {"Color of the sky?", "Blue"},
    {"Pi to two decimals?", "3.14"},
    {"Largest ocean?", "Pacific"},
    {"Capital of Egypt?", "Cairo"},
    {"Element with symbol O?", "Oxygen"},
    {"Inventor of the telephone?", "Alexander Graham Bell"},
    {"Number of continents?", "7"},
    {"Capital of Canada?", "Ottawa"},
    {"Painter of Mona Lisa?", "Leonardo da Vinci"},
    {"Fastest land animal?", "Cheetah"},
    {"Capital of Germany?", "Berlin"},
    {"Days in a leap year?", "366"}
  ]

  @spec dataset() :: [Dsxir.Example.t()]
  def dataset do
    Enum.map(@qa_pairs, fn {q, a} ->
      Dsxir.Example.new(%{q: q, a: a}, input_keys: [:q])
    end)
  end

  @spec trainset_10() :: [Dsxir.Example.t()]
  def trainset_10, do: Enum.take(dataset(), 10)

  @spec holdout_10() :: [Dsxir.Example.t()]
  def holdout_10, do: dataset() |> Enum.drop(10) |> Enum.take(10)

  @spec devset_20() :: [Dsxir.Example.t()]
  def devset_20, do: dataset() |> Enum.drop(10) |> Enum.take(20)

  @doc "Strict equality after case-folding and whitespace trim. trace ignored."
  @spec exact_match(Dsxir.Example.t(), Dsxir.Prediction.t(), nil | list()) :: boolean()
  def exact_match(
        %Dsxir.Example{data: %{a: expected}},
        %Dsxir.Prediction{fields: %{a: actual}},
        _trace
      ) do
    String.downcase(String.trim(actual)) == String.downcase(String.trim(expected))
  end

  def exact_match(_, _, _), do: false

  @spec exact_match_two_step(Dsxir.Example.t(), Dsxir.Prediction.t(), nil | list()) :: boolean()
  def exact_match_two_step(
        %Dsxir.Example{data: %{a: expected}},
        %Dsxir.Prediction{fields: %{a: actual}},
        _trace
      ) do
    String.downcase(String.trim(actual)) == String.downcase(String.trim(expected))
  end

  def exact_match_two_step(_, _, _), do: false
end
