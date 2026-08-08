# Native Agent Integrations

This directory is AgentGuard's public integration surface for agent runtimes.
It owns the reusable knowledge required to connect each runtime to the shared
`agent-hook-*` protocol:

- native lifecycle and tool event names
- tool matchers and timeout budgets
- `AGENTGUARD_NAME` and stable session identity mapping
- translation from a runtime's payloads to AgentGuard's canonical payloads
- compatibility exceptions for events a runtime does not support

Configuration managers and dotfile repositories should not copy that knowledge.
They own whether an integration is enabled, how a native fragment is layered
into an existing user configuration, and any user or machine policy around it.
That boundary keeps one tested runtime adapter reusable by consumers with very
different configuration-management strategies.

## Assets

| Runtime | Public asset | Shape |
| --- | --- | --- |
| Shared JSON/TOML lifecycle | `_shared/reconcile-hooks.jq` | Provider-generation reconciliation filter |
| Claude Code | `claude/hooks.json` | Hook-only JSON settings fragment |
| Codex | `codex/hooks.toml` | Hook activation and hook-only TOML fragment |
| Gemini CLI | `gemini/hooks.json` | Hook-only JSON settings fragment |
| Muse | `muse/hooks.json` | Supported hook-only JSON settings fragment |
| OpenCode | `opencode/agentguard.js` | Native plugin adapter |

The declarative fragments deliberately contain no permissions, allowlists,
models, MCP servers, UI preferences, paths, hostnames, or environment-specific
policy. Keeping them policy-free is what makes the same assets safe to consume
outside the repository that first needed them.

The fragments remain native JSON or TOML instead of being generated from a
lowest-common-denominator schema. These runtimes differ in event vocabulary,
matcher syntax, timeout behavior, and supported lifecycle events. Committed
native assets make those differences visible in review and avoid hiding
runtime-specific compatibility behind generator conditionals.

## Consumption

When AgentGuard is managed by Shdeps, resolve assets through its public API
rather than reconstructing installation paths:

```bash
shdeps dep-file cgraf78/agentguard \
  share/agentguard/integrations/claude/hooks.json
```

A consumer should merge a declarative fragment as one provider-owned layer and
keep personal policy in separate local layers. The OpenCode adapter should be
copied or linked only into a target the consumer explicitly owns; unmanaged
plugin files must never be overwritten.

Plain recursive merge is insufficient for a long-lived provider layer: it
cannot remove an event AgentGuard retired, and a changed command can remain
beside its replacement. JSON consumers—and TOML consumers that can convert a
document to JSON—should invoke `_shared/reconcile-hooks.jq` with the selected
agent name, the live document as `$d`, and the current provider fragment as
`$s`. The filter removes only historical commands carrying that AgentGuard
identity, preserves user hooks and runtime-owned metadata, and installs the
complete current generation. This keeps deletion and migration knowledge in
the same repository as the native mappings instead of distributing tombstone
lists across consumers.

Every declarative command clears `BASH_ENV` and `ENV` before starting an
`agent-hook-*` executable. Those variables can execute shell code before a hook
launcher reaches its own safeguards, so they are part of the integration's
security boundary rather than ambient user policy.

If a dependency lookup fails during an update, absence is not an instruction to
disable AgentGuard. Preserve the last known-good generated configuration and
report the dependency problem. This matters because a transient package or
network failure must not silently remove security hooks from an otherwise valid
installation.

AgentGuard publishes assets but does not mutate `~/.claude`, `~/.codex`,
`~/.gemini`, `~/.config/muse`, or `~/.config/opencode`. Consumers retain control
over activation, merge ordering, ownership markers, and rollback behavior.

## Compatibility Tests

`test/suites/integration-assets-test` parses every declarative asset, pins its
event mapping, matchers, timeouts, identity injection, and referenced hook
executables, and exercises provider upgrade/retirement while retaining user
hooks and mutable runtime state. `test/suites/opencode-agentguard-test`
exercises the executable adapter's complete callback surface and failure
behavior. Downstream consumers should test only their merge or installation
mechanics plus a small end-to-end wiring smoke test; duplicating AgentGuard's
protocol suite would let the copies drift independently.
