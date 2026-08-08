# Claude Code Integration

`hooks.json` is AgentGuard's complete hook-only Claude Code settings fragment.
It owns Claude's lifecycle events, tool matchers, timeout budgets, hook commands,
and session-identity wiring. It intentionally contains no permission rules or
other user settings.

Consume it with `../_shared/reconcile-hooks.jq` as one provider-owned generation,
then put personal or machine policy in a separate later layer. Reconciliation
lets AgentGuard change a command or retire an event without accumulating stale
Claude groups, while leaving user-owned hooks intact. If either asset cannot be
refreshed, preserve the complete last valid settings target rather than treating
dependency failure as an explicit opt-out.

The exact native contract is validated by
`test/suites/integration-assets-test`. Change event mappings here and in that
test together; downstream consumers should test only their merge mechanics.
