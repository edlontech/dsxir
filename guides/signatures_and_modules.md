# Signatures and Modules

Signatures declare a typed input/output contract for a single LM call.
Modules compose one or more signatures into a runnable program.

## Signatures

Declare a typed input/output contract for one LM call:

```elixir
defmodule MyApp.AnswerQuestion do
  use Dsxir.Signature

  signature do
    instruction "Answer the user's question with a single short fact."
    input :question, :string
    output :answer, :string
  end
end
```

String-form signatures are also supported inline at the predictor
declaration site:

```elixir
predictor :foo, Dsxir.Predictor.Predict, signature: "question -> answer"
```

## Modules

Compose signatures into a program:

```elixir
defmodule MyApp.QA do
  use Dsxir.Module

  predictor :answer, Dsxir.Predictor.Predict,
    signature: MyApp.AnswerQuestion

  def forward(prog, %{question: q}) do
    call(prog, :answer, %{question: q})
  end
end

prog = Dsxir.Program.new(MyApp.QA)
{_prog, pred} = MyApp.QA.forward(prog, %{question: "Capital of France?"})
pred[:answer]
```
