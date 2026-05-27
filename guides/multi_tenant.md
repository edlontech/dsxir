# Multi-tenant

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

Telemetry events auto-merge the per-context `:metadata`, so cost
dashboards filter by tenant for free — see [Telemetry](telemetry.md).
