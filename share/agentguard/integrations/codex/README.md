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

## Shell execution metadata

Codex may run a hook in its host directory while reporting the command's
execution directory in the native top-level `cwd`. AgentGuard validates that
field and uses it for shell guards and repository bookkeeping. An invalid or
inaccessible directory blocks pre-execution inspection; after execution it
skips repository bookkeeping while retaining output inspection. Fields inside
`tool_input` cannot override it: Codex's Bash-compatible input contains only
`command`, and an ignored input field must not bypass protections.

Codex 0.165.0 still reports its session directory instead of the shell's
`workdir`. AgentGuard cannot recover information the host omitted. Use explicit
`git -C /absolute/repository ...` commands on these releases; session-start
context includes this guidance. The protected-home guards remain enabled.
Runtimes that report the corrected native `cwd` need no configuration change.

Codex also sends shell output as a string without an exit status. AgentGuard
keeps that status unknown; output text cannot establish success. Watch
obligations remain conservative, and an unknown-status merge or close prompts
one-shot reconciliation through the existing `git pr-watch` producer. See
`../../../../docs/watch-protocol.md` for the status and completion contract.
