# dsxir

Elixir port of DSPy. Declarative LM programming with typed signatures,
composable modules, prompt-as-data optimization, and BEAM-native
concurrency.

## Getting Started

Add `dsxir` to your dependencies:

```elixir
def deps do
  [{:dsxir, "~> 0.1"}] # x-release-please-version
end
```

Configure the LM at boot:

```elixir
Dsxir.configure(
  lm: {Dsxir.LM.Sycophant, [model: "openai:gpt-4o-mini"]},
  adapter: Dsxir.Adapter.Chat
)
```

Credentials are NEVER passed to `Dsxir.configure/1` — they flow through
`Dsxir.context/2` per request (see [Multi-tenant](guides/multi_tenant.md)).

## A first program

Declare a typed signature, compose it into a module, and run it:

```elixir
defmodule MyApp.AnswerQuestion do
  use Dsxir.Signature

  signature do
    instruction "Answer the user's question with a single short fact."
    input :question, :string
    output :answer, :string
  end
end

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

## Documentation

- [Signatures and Modules](guides/signatures_and_modules.md) — typed
  contracts and how to compose them into programs.
- [Inference-time wrappers](guides/inference_wrappers.md) — `BestOfN`
  and `Refine` reward-sampling wrappers.
- [Optimizers](guides/optimizers.md) — `LabeledFewShot`,
  `BootstrapFewShot`, `MIPROv2`, and `COPRO`.
- [Runtime Programs](guides/runtime_programs.md) — author programs as
  data instead of code.
- [Multi-tenant](guides/multi_tenant.md) — per-request credentials,
  context, and `call_plugs`.
- [Telemetry](guides/telemetry.md) — the canonical event vocabulary and
  cost measurements.

## Tutorials

- [Email Information Extraction](guides/tutorials/email_extraction.livemd)
  — classify, extract, summarize, and propose action items over an
  inbox, then compile a few-shot version with
  `Dsxir.Optimizer.BootstrapFewShot`. Livebook: `livebook server
  guides/tutorials/email_extraction.livemd` from a checkout.
- [Inference-time Wrappers](guides/tutorials/inference_time_wrappers.livemd)
  — trade per-call budget for reliability with `BestOfN`, `Refine`,
  `Ensemble`, and `MultiChainComparison`, worked over a single
  Cognitive-Reflection-Test question.

## Comparing to DSPy

dsxir mirrors DSPy's surface where reasonable; some shapes differ:

| DSPy | dsxir |
| --- | --- |
| `dspy.configure(lm=...)` | `Dsxir.configure(lm: {Impl, config})` |
| `dspy.Signature` (Pydantic) | `use Dsxir.Signature` (Spark + Zoi) |
| `signature.demos = [...]` (mutation) | `%Dsxir.Program{}` with per-predictor `%State{}` |
| `metric(example, pred, trace=None)` | `(example, pred, trace) -> number()` |
| `dspy.inspect_history` | `Dsxir.History.enable/0` + `last/1` |
| `dspy.History` value type | `Dsxir.Primitives.History` |
