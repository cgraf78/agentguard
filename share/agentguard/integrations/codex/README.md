# Codex Integration

`hooks.toml` is AgentGuard's native Codex hook fragment. It enables the Codex
hook feature and declares the lifecycle/tool hook tables, matchers, timeouts,
commands, and session identity needed by AgentGuard. Models, approval policy,
profiles, MCP servers, UI settings, and project trust are deliberately absent.

Convert the live TOML and this fragment to JSON, apply
`../_shared/reconcile-hooks.jq`, render the result back to TOML, and only then
merge consumer-owned Codex settings. The shared filter deliberately preserves
non-array `hooks` children such as Codex's mutable trust records while replacing
AgentGuard's complete event generation. Consumers remain responsible for native
serialization, cache invalidation, and trust refresh; those are
configuration-management concerns, while this directory owns the reusable
runtime mapping and ownership predicate.

Treat lookup failure for either asset as a failed refresh, not as permission to
erase or partially update the live config. The canonical mapping is validated by
`test/suites/integration-assets-test`, so downstream tests can use neutral TOML
fixtures for their merge engines instead of duplicating these tables.
