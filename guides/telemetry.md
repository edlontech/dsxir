# Telemetry

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
