# dsxir

Elixir port of DSPy. Declarative LM programming with typed signatures,
composable modules, prompt-as-data optimization, and BEAM-native
concurrency.

## Getting Started

Add `dsxir` to your dependencies:

```elixir
def deps do
  [{:dsxir, "~> 0.1"}]
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
`Dsxir.context/2` per request (see Multi-tenant below).

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

## Optimizers

Compile demos from labeled data:

```elixir
{:ok, compiled, _stats} =
  Dsxir.compile(
    Dsxir.Optimizer.BootstrapFewShot,
    prog,
    trainset,
    &MyApp.Metric.f1/3,
    max_bootstrapped_demos: 4
  )

Dsxir.save!(compiled, "qa.v1.json")
```

`Dsxir.Optimizer.LabeledFewShot` (no LM calls) and
`Dsxir.Optimizer.BootstrapFewShot` (trace-driven, with diversity) are
the two v0 optimizers.

## Multi-tenant

Tenant data flows through `Dsxir.context/2`, never through
`Dsxir.configure/1`. The framework auto-merges `:metadata` into every
telemetry event so cost dashboards filter by tenant for free:

```elixir
def call(conn, _opts) do
  tenant = conn.assigns.tenant

  Dsxir.context(
    [
      lm: {Dsxir.LM.Sycophant,
           [model: tenant.model_id, api_key: tenant.api_key]},
      adapter: tenant.adapter,
      cache: false,
      metadata: %{tenant_id: tenant.id,
                  request_id: conn.assigns.request_id},
      call_plugs: [&MyApp.Quota.check/1, &MyApp.Audit.before_call/1]
    ],
    fn ->
      program = Dsxir.load!(MyApp.QA, "tenants/#{tenant.id}/qa.json")
      {_program, pred} = MyApp.QA.forward(program, %{question: conn.params["q"]})
      pred
    end
  )
end
```

Notes:

- `Dsxir.configure/1` is for defaults only. It rejects `tenant_*` keys
  (both top-level and nested inside `:metadata`) and `:lm` tuples whose
  config carries a non-nil `:api_key`. Tenant data flows through
  `Dsxir.context/2`.
- `cache: false` is the recommended default inside tenant contexts.
- `call_plugs` is the hook point for quota, audit, and rate-limit
  policies. v0 ships the hook only — consumers write their own plugs
  as 1-arity functions `(%Dsxir.CallContext{} -> :ok | {:halt, reason})`.

## Telemetry

Attach handlers to the canonical event vocabulary:

```elixir
:telemetry.attach(
  "my-app-cost-dashboard",
  [:dsxir, :predictor, :stop],
  &MyApp.Telemetry.record_cost/4,
  nil
)
```

Every event auto-merges `Dsxir.Settings.resolve(:metadata, %{})` into
its metadata. Token measurements (`tokens_in`, `tokens_out`, `cost`)
are always present on `[:dsxir, :predictor, :stop]`; their value is
`nil` when the upstream LM did not report usage. See `Dsxir.Telemetry`
for the full event list.

## Tutorials

- [Email Information Extraction](guides/tutorials/email_extraction.livemd)
  — classify, extract, summarize, and propose action items over an
  inbox, then compile a few-shot version with
  `Dsxir.Optimizer.BootstrapFewShot`. Livebook: `livebook server
  guides/tutorials/email_extraction.livemd` from a checkout.

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

