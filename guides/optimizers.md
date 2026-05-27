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
