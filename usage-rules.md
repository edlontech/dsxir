# Rules for working with dsxir

dsxir is an Elixir port of DSPy: declarative LM programming with typed
signatures, composable modules, prompt-as-data optimization, and BEAM-native
concurrency. `Dsxir` is a thin facade — predictors, adapters, optimizers, and
LM impls live under their own module names (`Dsxir.Predictor.*`,
`Dsxir.Adapter.*`, `Dsxir.Optimizer.*`, `Dsxir.LM.*`).

## Configuration vs. per-request context

- `Dsxir.configure/1` sets node-wide defaults. Call it **once at boot**, never
  per request.
- **Credentials and tenant data never go through `configure/1`.** It rejects
  `tenant_*` keys (top-level and nested in `:metadata`) and any `:lm` tuple
  whose config carries a non-nil `:api_key`, dropping them with a warning.
- Per-request settings — including credentials — flow through `Dsxir.context/2`,
  which pushes a scoped frame for the duration of the function.

```elixir
# boot
Dsxir.configure(lm: {Dsxir.LM.Sycophant, [model: "openai:gpt-4o-mini"]},
                adapter: Dsxir.Adapter.Chat)

# per request (e.g. a Plug)
Dsxir.context(
  [lm: {Dsxir.LM.Sycophant, [model: tenant.model_id, api_key: tenant.api_key]},
   cache: false,
   metadata: %{tenant_id: tenant.id}],
  fn -> ... end)
```

The `:lm` setting is always `nil | {impl_module, config :: keyword()}`;
credentials live inside `config`, not at the top level. Prefer `cache: false`
inside tenant contexts.

## Signatures

A signature is a typed input/output contract for one LM call.

```elixir
defmodule MyApp.AnswerQuestion do
  use Dsxir.Signature

  signature do
    instruction "Answer the user's question with a single short fact."
    input :question, :string
    output :answer, :string, desc: "A direct factual answer."
  end
end
```

Inline string form (`"inputs -> outputs"`, optional `name: type`) works
anywhere a signature is expected — pass it to a `predictor` declaration, or
compile via `Dsxir.Signature.from_string/2` (`{:ok, compiled}`) /
`from_string!/2` (raises `Dsxir.Errors.Invalid.Signature`).

## Modules and programs

Declare programs with `use Dsxir.Module`, declare each predictor with the
`predictor` entity, then implement `forward/2`. Inside `forward/2`, dispatch
with `call(prog, :name, inputs)`.

```elixir
defmodule MyApp.QA do
  use Dsxir.Module

  predictor :answer, Dsxir.Predictor.Predict, signature: MyApp.AnswerQuestion

  def forward(prog, %{question: q}) do
    call(prog, :answer, %{question: q})
  end
end

prog = Dsxir.Program.new(MyApp.QA)
{_prog, pred} = MyApp.QA.forward(prog, %{question: "Capital of France?"})
```

- A `%Dsxir.Program{}` is **immutable data threaded explicitly** — never
  ambient or process state. `call/3` and `forward/2` return
  `{updated_prog, prediction}`; keep the returned program.
- Predictor names in `call/3` must be declared via `predictor`. Literal-atom
  names are checked at compile time (typos caught by the verifier); dynamic
  names are validated at runtime.
- `Dsxir.Program.new/1` raises `Dsxir.Errors.Invalid.Module` for an atom that
  is not a `Dsxir.Module`.

## Predictions

`%Dsxir.Prediction{}` carries the validated output `fields` map and implements
`Access`: `pred[:answer]` and `pred.fields.answer` are equivalent. It also
carries `completions`, `lm_usage`, and `skipped`.

## Predictors (`Dsxir.Predictor.*`)

- `Predict` — base single-call predictor.
- `ChainOfThought` — prepends a `:reasoning` output field (on
  `pred.fields.reasoning`); otherwise identical to `Predict`.
- `ReAct` — tool-using loop. Declare with `tools:` and `max_iters:`. Keep its
  `trace_name` **distinct** from any declared predictor name — collision is a
  footgun under bootstrap optimization. Exhausting `max_iters` raises
  `Dsxir.Errors.Framework.PredictorError`.
- `Parallel` — `Dsxir.Predictor.Parallel.run/3` runs N calls concurrently and
  returns `{prog, results}`, results in input order as `{:ok, prediction}` /
  `{:error, exception}`. It does not raise; the caller decides.

Predictors that synthesize fields beyond the signature report them via the
optional `c:augmented_outputs/1` callback (so artifacts validate on save/load).

## Adapters (`Dsxir.Adapter.*`)

`Chat` (the `[[ ## marker ## ]]` text protocol, default) and `Json`
(provider-native structured output). Set via `:adapter`. Predictors and
adapters never call a provider SDK directly — they go through the active LM.

## Metrics

A metric is **any 3-arity function**:

```elixir
(Dsxir.Example.t(), Dsxir.Prediction.t(), trace :: nil | list()) ->
  number() | boolean()
```

`trace` is `nil` outside `Dsxir.with_trace/1`; ignore it if unused. Always
invoke metrics via `Dsxir.Metric.apply/4` — it coerces booleans to `1.0`/`0.0`
and raises `Dsxir.Errors.Invalid.Metric` on any other return. Never branch on a
metric's raw return shape.

## Examples

`Dsxir.Example.new(data, input_keys: [...])` holds a unified `data` map; the
`input_keys` set splits inputs from labels. `Dsxir.Example.inputs/1` projects
down to inputs.

## Optimizers (`Dsxir.Optimizer.*`)

Compile demos/instructions from labeled data via `Dsxir.compile/5`, which
returns `{:ok, compiled_program, stats}` — a normal `%Dsxir.Program{}`.

```elixir
{:ok, compiled, stats} =
  Dsxir.compile(Dsxir.Optimizer.BootstrapFewShot, prog, trainset,
                &MyApp.Metric.f1/3, max_bootstrapped_demos: 4)
```

- `LabeledFewShot` — samples demos from labeled data; no LM calls.
- `BootstrapFewShot` — trace-driven demo synthesis with diversity. Honors
  `degraded_demos:` (`:exclude` by default) for runtime-program skipped chains.
- `KNNFewShot` — nearest-neighbor demo selection.
- `MIPROv2` — joint instruction + demo search. Takes `auto: :light | :medium |
  :heavy`; overrides include `:proposer_lm`, `:sampler`, `:batch_size`, `:seed`.
- `GEPA` — reflective Pareto-frontier optimizer. Use a feedback-bearing metric
  (`Dsxir.Metric.ScoreWithFeedback`) so reflection has signal.

## Evaluation

`Dsxir.evaluate/2` runs a devset (fan-out under `Dsxir.TaskSupervisor`,
per-worker settings replay). `evaluate!/2` raises after the run if any row
errored. Per-row errors are caught, classified, and counted — a single failure
does not abort the run.

## Persistence

`Dsxir.save/2` / `save!/2` write a program to JSON; `Dsxir.load/3` / `load!/3`
read it back against a target module.

```elixir
Dsxir.save!(compiled, "qa.v1.json")
program = Dsxir.load!(MyApp.QA, "qa.v1.json")
```

## Runtime programs

Programs can be authored at runtime as plain data instead of `use
Dsxir.Module`. `Dsxir.RuntimeProgram.from_map/2` parses a JSON-ish payload
(inputs, outputs, nodes, edges), validates impls/signatures/edge wiring/DAG
acyclicity/guards, and optionally persists via a configured store.
`Dsxir.Program.from_runtime/1` makes it runnable.

- Nodes may carry a `guard_source` (the Predicate DSL, e.g.
  `"length(input.question) > 0"`); on `false` the node is skipped. Skips cascade
  along `:required` edges; `:optional` downstreams are marked `degraded`.
- The executor `on_skip` opt selects `:raise` (default), `:tagged_tuple`
  (`{:partial, prediction}`), or `nil` (`%Prediction{skipped: [...]}` with nil
  fields).
- All optimizers and `Dsxir.Evaluate` accept runtime programs transparently.
- **Never `Code.eval_string` or `String.to_atom` a runtime payload in
  production code.** `mix dsxir.check.no_eval` enforces this.

## Telemetry

Attach to the canonical events (see `Dsxir.Telemetry`). Every event auto-merges
`Dsxir.Settings.resolve(:metadata, %{})`, so setting `:metadata` in context
makes cost dashboards filter by tenant for free.

```elixir
:telemetry.attach("cost", [:dsxir, :predictor, :stop], &handler/4, nil)
```

`tokens_in`, `tokens_out`, and `cost` are always present on
`[:dsxir, :predictor, :stop]`; their value is `nil` when the LM reported no
usage.

## LM providers (`Dsxir.LM`)

LM impls implement the `Dsxir.LM` behaviour (`generate_text/3`, optional
`generate_object/4` and `embed/3`). Predictors/adapters dispatch through it and
never touch a provider SDK. `Dsxir.LM.Sycophant` is the shipped real
implementation (optional dependency). In tests, stub LM callbacks with `mimic`
rather than building bespoke fakes.

## Tracing

`Dsxir.with_trace/1` opens a process-local accumulator; the block must return
`{program, prediction}` and the helper returns `{program, prediction, trace}`.
The trace **does not cross process boundaries** — calls inside spawned tasks
(`Parallel`, user `Task`s) are not recorded.

## Common pitfalls

- Putting credentials or `tenant_*` data in `configure/1` — use `context/2`.
- Discarding the program returned by `call/3` / `forward/2` — thread it.
- Branching on a metric's raw return instead of using `Dsxir.Metric.apply/4`.
- Reaching for a GenServer/Agent to "hold" a program — programs are plain data.
- Expecting traces from inside parallel/spawned work.
- Reusing a `ReAct` `trace_name` that matches a declared predictor name.
