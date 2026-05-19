defmodule Dsxir.Test.Fixtures.AnswerProgram do
  @moduledoc false
  use Dsxir.Module

  predictor :answer, Dsxir.Predictor.Predict, signature: Dsxir.Test.Fixtures.AnswerQuestion

  def forward(prog, %{question: q}) do
    call(prog, :answer, %{question: q})
  end
end

defmodule Dsxir.Test.Fixtures.ThreePredictors do
  @moduledoc false
  use Dsxir.Module

  predictor :a, Dsxir.Predictor.Predict, signature: Dsxir.Test.Fixtures.AnswerQuestion
  predictor :b, Dsxir.Predictor.Predict, signature: Dsxir.Test.Fixtures.AnswerQuestion
  predictor :c, Dsxir.Predictor.Predict, signature: Dsxir.Test.Fixtures.AnswerQuestion

  def forward(prog, %{question: q}) do
    call(prog, :a, %{question: q})
  end
end

defmodule Dsxir.Test.Fixtures.ChainOfThoughtProgram do
  @moduledoc false
  use Dsxir.Module

  predictor :think, Dsxir.Predictor.ChainOfThought, signature: Dsxir.Test.Fixtures.AnswerQuestion

  def forward(prog, %{question: q}) do
    call(prog, :think, %{question: q})
  end
end

defmodule Dsxir.Test.Fixtures.RankProgram do
  @moduledoc false
  use Dsxir.Module

  predictor :rank, Dsxir.Predictor.Predict, signature: Dsxir.Test.Fixtures.RankItems

  def forward(prog, %{query: q, items: items}) do
    call(prog, :rank, %{query: q, items: items})
  end
end

defmodule Dsxir.Test.Fixtures.ArithmeticQASig do
  @moduledoc false
  use Dsxir.Signature

  signature do
    instruction "Solve the arithmetic word problem. Reply with the numeric answer only."
    input :question, :string
    output :answer, :string, desc: "The final number, no units or punctuation."
  end
end

defmodule Dsxir.Test.Fixtures.Programs.ArithmeticQA do
  @moduledoc """
  Minimal QA-style program over `Dsxir.Test.Fixtures.ArithmeticQASig`. One
  predictor named `:qa`, invoked with the inbound `:question` field.
  """
  use Dsxir.Module

  predictor :qa, Dsxir.Predictor.Predict, signature: Dsxir.Test.Fixtures.ArithmeticQASig

  def forward(prog, %{question: q}), do: call(prog, :qa, %{question: q})
end

defmodule Dsxir.Test.Fixtures.Programs do
  @moduledoc """
  Synthetic GSM8K-shaped arithmetic word problems for fixture programs.

  Generation is deterministic for a given seed via an explicitly-threaded
  `:rand` state (`:rand.seed_s/2` + `:rand.uniform_s/2`) so that concurrent
  generators do not interfere with each other's PRNG state.
  """

  @templates [
    {"Alice has {a} apples and buys {b} more. How many apples does she have now?", :add},
    {"There are {a} birds on a wire. {b} fly away. How many remain?", :sub},
    {"A box holds {a} pencils. You have {b} identical boxes. How many pencils in total?", :mul},
    {"{a} cookies are shared equally among {b} kids. How many cookies per kid?", :div},
    {"Bob ran {a} kilometers on Monday and {b} on Tuesday. How many in total?", :add},
    {"A jar had {a} candies. After eating {b}, how many are left?", :sub}
  ]

  @default_seed {11, 12, 13}

  @doc """
  Generate a deterministic dataset of `n_train + n_val` unique arithmetic
  examples and split into a `{trainset, valset}` tuple. Generating both halves
  from a single pool of unique examples guarantees disjointness, regardless of
  the template/range overlap.
  """
  @spec arithmetic_dataset(pos_integer(), pos_integer(), :rand.seed()) ::
          {[Dsxir.Example.t()], [Dsxir.Example.t()]}
  def arithmetic_dataset(n_train, n_val, seed \\ @default_seed)
      when is_integer(n_train) and n_train > 0 and is_integer(n_val) and n_val > 0 do
    total = n_train + n_val
    examples = generate_unique(total, seed)
    Enum.split(examples, n_train)
  end

  defp generate_unique(n, seed) do
    state = :rand.seed_s(:exsss, seed)
    do_generate_unique(n, state, MapSet.new(), [])
  end

  defp do_generate_unique(0, _state, _seen, acc), do: Enum.reverse(acc)

  defp do_generate_unique(remaining, state, seen, acc) do
    {example, state} = next_example(state)
    key = example.data.question

    if MapSet.member?(seen, key) do
      do_generate_unique(remaining, state, seen, acc)
    else
      do_generate_unique(remaining - 1, state, MapSet.put(seen, key), [example | acc])
    end
  end

  defp next_example(state) do
    {template, op, state} = pick_template(state)
    {a, b, answer, state} = sample(op, state)

    question =
      template
      |> String.replace("{a}", Integer.to_string(a))
      |> String.replace("{b}", Integer.to_string(b))

    example =
      Dsxir.Example.new(%{question: question, answer: Integer.to_string(answer)},
        input_keys: [:question]
      )

    {example, state}
  end

  defp pick_template(state) do
    {idx, state} = :rand.uniform_s(length(@templates), state)
    {template, op} = Enum.at(@templates, idx - 1)
    {template, op, state}
  end

  defp sample(:add, state) do
    {a, state} = uniform_in(state, 5, 45)
    {b, state} = uniform_in(state, 5, 45)
    {a, b, a + b, state}
  end

  defp sample(:sub, state) do
    {a, state} = uniform_in(state, 20, 60)
    {b, state} = :rand.uniform_s(a - 1, state)
    {a, b, a - b, state}
  end

  defp sample(:mul, state) do
    {a, state} = uniform_in(state, 2, 11)
    {b, state} = uniform_in(state, 2, 11)
    {a, b, a * b, state}
  end

  defp sample(:div, state) do
    {b, state} = uniform_in(state, 2, 10)
    {q, state} = uniform_in(state, 2, 11)
    {b * q, b, q, state}
  end

  defp uniform_in(state, lo, hi) when hi > lo do
    {n, state} = :rand.uniform_s(hi - lo + 1, state)
    {lo + n - 1, state}
  end
end
