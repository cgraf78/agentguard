# Muse Integration

`hooks.json` is AgentGuard's hook-only Muse settings fragment. It contains the
supported Muse lifecycle/tool events, matchers, timeouts, commands, and session
identity without inheriting permission policy from any particular dotfiles
repository.

The supported event set is intentionally a Muse compatibility decision owned
here, not Claude parity assumed by a consumer. Apply this generation through
`../_shared/reconcile-hooks.jq` before consumer-owned settings and keep
permissions or other user policy in separate later fragments. The reconciler
removes historical AgentGuard events that Muse no longer supports without a
Muse-specific deletion list downstream. If refresh fails, preserve the complete
last valid settings target.

The exact compatibility contract lives in
`test/suites/integration-assets-test`; downstream suites should use neutral
fixtures to test their merge logic rather than copying Muse's event map.
