# Shared Integration Support

`reconcile-hooks.jq` is the provider-owned refresh operation for declarative
AgentGuard hook fragments. It accepts the runtime name as `$agent`, the live
settings document through `--slurpfile d`, and the current native fragment
through `--slurpfile s`.

The separate filter exists because configuration merge and provider ownership
are different concerns. A consumer knows how to read and atomically write its
target, but only AgentGuard knows which historical command envelopes belong to
it. Keeping that predicate here lets one release replace a changed command or
retire an unsupported event everywhere without teaching each dotfile manager
the old runtime vocabulary.

The filter removes AgentGuard commands individually inside hook groups. That
detail preserves a user command that shares a matcher/group with AgentGuard.
It also leaves non-array entries below the hook table untouched because runtimes
such as Codex keep mutable trust metadata there. The incoming fragment is then
installed as the complete current provider generation; unrelated settings,
user hook events, and other agents' commands remain intact.

A consumer should stage the filter output, validate it in the target's native
format, and replace the destination only after the whole operation succeeds.
If either provider asset is unavailable or invalid, preserve the complete
last-known-good destination and report a failed refresh. AgentGuard's integration
tests own exact reconciliation semantics; consumer tests should use neutral
fixtures to verify resolution, staging, and failure behavior.
