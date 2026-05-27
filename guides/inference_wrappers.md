# Inference-time wrappers

These modules wrap a compiled program and are called directly from a
`forward/2` body — they are not declared predictors.

## BestOfN

`Dsxir.Predictor.BestOfN` runs the program up to `n` times with diverse
sampling, scores each result with a `reward_fn.(inputs, %Dsxir.Prediction{})
-> number()` callback, and returns the highest-reward attempt. Pass
`:threshold` to stop early once a reward meets or exceeds it.

```elixir
{_program, prediction} =
  Dsxir.Predictor.BestOfN.run(
    program,
    %{question: q},
    &MyApp.reward/2,
    n: 5,
    threshold: 0.9
  )
```

Opts: `:n` (required), `:threshold` (early-stop, default `nil`),
`:fail_count` (failures tolerated before re-raising, default `n`),
`:temperature` (sampling temperature, default `1.0`).

## Refine

`Dsxir.Predictor.Refine` is like `BestOfN` but reflective: after each
sub-threshold attempt it runs an internal `OfferFeedback` predictor over
the captured trace and injects per-predictor corrective advice into the
next attempt through the `Dsxir.Settings` `:hints` channel.

```elixir
{_program, prediction} =
  Dsxir.Predictor.Refine.run(
    program,
    %{question: q},
    &MyApp.reward/2,
    n: 5,
    threshold: 0.9
  )
```

Accepts the same opts as `BestOfN` plus `:feedback_lm` (`{module, config}`
tuple) to override the LM used for the `OfferFeedback` call. With
`threshold: nil`, feedback is generated after every attempt, so each
attempt after the first is refined from the previous one.
