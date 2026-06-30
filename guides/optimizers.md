# Optimizers

Optimizers compile a program against labeled data and a metric, producing
a new program with tuned demos and/or instructions.

## Few-shot compilation

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
the two v0 few-shot optimizers.

## MIPROv2

`Dsxir.Optimizer.MIPROv2` jointly searches over candidate instructions
and demo bundles. It bootstraps demo candidates, asks a proposer LM for
candidate instructions grounded in program and dataset summaries, then
runs a sampler-driven search (TPE by default) with periodic full-valset
reranks of the top trials.

```elixir
{:ok, compiled, stats} =
  Dsxir.compile(
    Dsxir.Optimizer.MIPROv2,
    program,
    trainset,
    &MyApp.Metric.f1/3,
    auto: :medium
  )

stats.best_score
```

`auto:` accepts `:light | :medium | :heavy` (see `Dsxir.Optimizer.MIPROv2.Auto`).
Notable overrides: `:proposer_lm`, `:sampler`, `:batch_size`, `:seed`,
`:minibatch_full_eval_steps`, `:top_k_full_eval`.

## COPRO

`Dsxir.Optimizer.COPRO` is an instruction-only prompt optimizer that
tunes each predictor's instruction independently by greedy coordinate
ascent. For each round (up to `depth` rounds), it generates `breadth`
candidate instructions per predictor, scores each against the full
training set, and keeps the best. It does not touch demos or few-shot
examples, making it cheaper than MIPROv2 and a good warm-up step before
a full joint search.

```elixir
{:ok, compiled, stats} =
  Dsxir.compile(
    Dsxir.Optimizer.COPRO,
    program,
    trainset,
    &MyApp.Metric.f1/3,
    auto: :medium
  )

stats.best_score
```

`auto:` accepts `:light | :medium | :heavy` (see `Dsxir.Optimizer.COPRO.Auto`).
Preset values — light: breadth 4 / depth 2, medium: breadth 6 / depth 3,
heavy: breadth 10 / depth 4. Notable overrides: `:breadth`, `:depth`,
`:init_temperature`.

## SIMBA

`Dsxir.Optimizer.SIMBA` (Stochastic Introspective Mini-Batch Ascent) searches
over demos and instructions via mini-batch trajectory sampling and variance-driven
bucketing. Each step softmax-picks source programs from a growing pool, runs
diverse executions per mini-batch example, and applies one of two strategies:
`AppendDemo` adds the best I/O trace as augmented demos, and `AppendRule` asks
a reflective LM to contrast better-vs-worse trajectory pairs and appends
per-predictor advice to each instruction. A post-loop finalize scores
evenly-spaced winners on the full trainset and returns the best.

Reach for SIMBA when you want both demo augmentation and self-reflective rule
generation in one mini-batch ascent pass. Prefer MIPROv2 for a sampler-driven
joint search over a large instruction proposal set, GEPA for a reflective
proposal search without the stochastic mini-batch loop, or COPRO when only
instructions need tuning.

```elixir
{:ok, compiled, stats} =
  Dsxir.compile(
    Dsxir.Optimizer.SIMBA,
    program,
    trainset,
    &MyApp.Metric.f1/3,
    auto: :medium
  )

stats.best_score
```

`auto:` accepts `:light | :medium | :heavy` (see `Dsxir.Optimizer.SIMBA.Auto`).

| Option | Default | Description |
| --- | --- | --- |
| `:auto` | `:medium` | Preset level. Determines `bsize`, `num_candidates`, `max_steps`, `max_demos`. |
| `:bsize` | preset | Mini-batch size drawn per step. |
| `:num_candidates` | preset | Candidate programs built and evaluated per step. |
| `:max_steps` | preset | Number of mini-batch steps (total optimization budget). |
| `:max_demos` | preset | Maximum augmented demos per predictor. |
| `:temperature_for_sampling` | `0.2` | Softmax temperature for source-program selection during trajectory sampling. |
| `:temperature_for_candidates` | `0.2` | Softmax temperature for source-program selection during candidate building. |
| `:sampling_temperature` | `1.0` | LM temperature for diverse trajectory samples. |
| `:demo_input_field_maxlen` | `100_000` | Character limit for input fields in augmented demos; longer fields are truncated. |
| `:num_threads` | `4` | Evaluator concurrency. |
| `:reflective_lm` | task LM | LM used by `AppendRule` for per-predictor advice generation. |
| `:seed` | `0` | RNG seed; makes a run deterministic. |

`:auto` preset values:

| Preset | `bsize` | `num_candidates` | `max_steps` | `max_demos` |
| --- | --- | --- | --- | --- |
| `:light` | 16 | 4 | 4 | 3 |
| `:medium` | 32 | 6 | 8 | 4 |
| `:heavy` | 48 | 8 | 12 | 6 |

SIMBA implements all four checkpointable `Dsxir.Optimizer` callbacks and works
with `Dsxir.OptimizerSession` for pause/resume across steps.
