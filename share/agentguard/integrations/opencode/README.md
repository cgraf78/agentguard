# OpenCode Integration

`agentguard.js` is the native OpenCode adapter for AgentGuard. OpenCode exposes
JavaScript plugin callbacks rather than a declarative hook table, so the adapter
translates those callbacks into the same payload contract consumed by the
PATH-visible `agent-hook-*` commands. Its default export provides a V1 `server`
entrypoint and a V2 `setup` entrypoint with the stable plugin ID `agentguard`.
Both entrypoints share one guard and lifecycle implementation.

## What the Adapter Owns

The adapter owns runtime-specific behavior that should be identical for every
consumer:

- lifecycle ordering and deduplication for session start, prompt, stop, and end
- pre/post routing for shell, edit, write, patch, and MCP tools
- OpenCode-to-AgentGuard payload normalization
- propagation of hook context back into OpenCode output
- protected pre-hook denial and protocol-failure behavior
- advisory handling for post-tool and lifecycle failures
- per-call state for concurrent tools and bounded cleanup for abandoned state
- audit events for every tool, prompt, permission request, and lifecycle event

It does not own permissions, OpenCode configuration beyond registering the
plugin, Hive Memory configuration, shell startup files, or machine policy.

## Ownership Marker

The first line of the provider asset is the stable marker
`// agentguard-managed:opencode-plugin`. A configuration manager may use that
exact line to distinguish an AgentGuard-owned installed copy from an unrelated
plugin at the same destination. Validate the marker on the resolved provider
asset before replacing anything, accept only explicitly documented legacy
markers as migration inputs, and never infer ownership from the filename alone.

This marker is deliberately part of the public integration contract. Without a
provider-owned identity, each consumer would invent a different heuristic and a
corrupt or misresolved source could overwrite an unmanaged user plugin.

## Hook Execution Boundary

The adapter resolves each `agent-hook-*` executable from `~/.local/bin` and then
`PATH`, and invokes the resolved executable directly. It does not launch through
`bash -c`. Before launch it removes `BASH_ENV`, `ENV`, exported Bash functions,
and inherited shell-option controls because Bash consumes those values before a
hook's first line—too early for the hook launcher's own scrub. Direct invocation
with that sanitized boundary avoids coupling the plugin to any consumer's shell
initialization.

Each child otherwise inherits the caller's ordinary environment, with
`AGENTGUARD_NAME` and `AGENTGUARD_SESSION_ID` set by the adapter. The `shell.env`
callback (V2: `shell.create.before`) exports the same generic keys into OpenCode's actual shell tool so
other AgentGuard-aware tools can attribute child activity without the adapter
depending on their vocabulary. V2 does not include session identity in shell
events, so the adapter wraps registered tool executors in an asynchronous
execution scope. Concurrent calls keep separate identities; shell processes
launched outside a tool execution receive an empty session ID to mask any
inherited parent-agent identity.

## Failure Semantics

Missing hook executables are advisory because OpenCode may load the plugin while
AgentGuard is still being installed. Once a protected pre-hook is found and
launched, denial, timeout, malformed successful output, input failure, or launch
failure rejects the protected tool call. Post-tool and lifecycle hooks cannot
undo completed work, so their failures are logged without rewriting the tool's
result.

Hook children run in a private POSIX process group. On timeout, input failure,
denial, nonzero exit, or malformed protected output, the adapter kills that
group before returning the failure. When trusted system copies of Python 3 and
`ps` are available, it additionally sweeps the private session for helpers that
deliberately created another process group. That helper runs Python in isolated
mode from a neutral directory, with absolute system executable paths and a
fixed system `PATH`, so a project cannot inject `sitecustomize.py`,
`subprocess.py`, `PYTHONPATH`, `python3`, or `ps` into cleanup; the narrower
group kill remains the non-executing fallback on minimal systems. Windows does
not use POSIX process-group cleanup.

Live MCP inventory refreshes are bounded to one second and cached briefly. A
timed-out or malformed local status response falls back to the last known or
configured server set, so an unavailable OpenCode status endpoint cannot hang
every otherwise unrelated tool call. That fallback is marked incomplete: a
known server still receives its normal guard, while an otherwise unmatched
canonical/resource identity or flattened `<server>_<tool>` identity fails
closed. A cold status failure therefore cannot turn a runtime-added MCP tool
into an unguarded call merely because it was absent from startup configuration.

## Audit Telemetry

The adapter sends each event to `agent-hook-telemetry` (see
`docs/telemetry.md`), the passive recorder the declarative fragments register
for every hook. Records use the guard hooks' snake_case envelope, with
`tool_use_id` taken from the OpenCode call ID on pre, post, and guard payloads
alike. A guarded tool keeps the canonical name and input its guard sees;
unguarded tools such as `read` and `grep`, and MCP helpers that fan out to
several servers, keep OpenCode's native name and arguments. Every call is
recorded before any guard runs, so a denied request still has its `PreToolUse`
record, and post records carry the full tool output, subject to the
recorder's payload cap.

| OpenCode source | Recorded event |
| --- | --- |
| first prompt of a session (lazy start) | `SessionStart` |
| `chat.message` / V2 `session.prompt` | `UserPromptSubmit` |
| `tool.execute.before` / `after` | `PreToolUse` / `PostToolUse` |
| tool error part / V2 `execute.after` error | `PostToolUseFailure` |
| `permission.ask` / V2 `permission.evaluate` ask | `PermissionRequest` |
| `experimental.session.compacting` / V2 `session.compaction.started` | `PreCompact` |
| `session.compacted` / V2 `session.compaction.ended` | `PostCompact` |
| `session.error` / V2 `session.execution.failed` | `StopFailure` |
| `session.error` with `MessageAbortedError` / V2 `session.execution.interrupted` | `Interrupt` |
| `session.idle` | `Stop`, unless that turn already recorded `StopFailure` or `Interrupt` |
| `session.deleted` or unload | `SessionEnd` |
| subagent prompt (child session) | `SubagentStart` on the parent |
| subagent `session.idle`, or deletion mid-turn | `SubagentStop` on the parent |

Lifecycle records follow the guard lifecycle, so internal title, summary, and
compaction sessions record no prompts or lifecycle events. An interrupted turn
is an `Interrupt`, not a failure, matching the runtimes that expose that event
natively; it keeps the V1 native error or the V2 `reason`. `StopFailure` and
`Interrupt` each end their turn in place of its `Stop` record, and, as in
Claude Code, the stop guard does not run for that turn. A V2 `superseded`
interruption names no turn and its turn never goes idle, so it is recorded
without suppressing the replacing turn's `Stop`. A failed MCP call reaches its
post guard as `PostToolUseFailure`, matching its audit record, with the
explicit error flag as well. A V2 background shell admitted as `running`
records only its `PreToolUse`, matching the post-hook exception below.

A task subagent runs in a child session that names its parent. As in the
other runtimes, its activity is filed under the top-level session (following
nested parents) with the child session ID as `agent_id`: each subagent turn
records `SubagentStart` (with `agent_type` and its task prompt) and
`SubagentStop` instead of the child's own session, prompt, and stop records,
and its tool records carry `agent_id`. Tool guards and the subagent's shell
also use the top-level session, as Claude's subagent tool hooks do, so guard
state such as edit churn is shared with the delegating agent. The child's
lifecycle guards (session start and end, prompt, stop) keep running under its
own session ID so they can never initialize or clean up the parent's state.
Links come from V1 `session.created` and V2 `session.get` or
`session.created`.

Each record is a separate recorder process, stamped when it finishes, so the
timeline guarantees only two orderings: a call's post or failure record lands
after its own `PreToolUse`, and a session's lifecycle records land in dispatch
order. Tool records are not ordered against lifecycle records or against other
calls; a `PreToolUse` can be stamped before the prompt that led to it. Join
records on `tool_use_id` rather than relying on position.

The recorder never affects a tool result or guard decision: it is spawned
fire-and-forget, its output is discarded, and a missing, failing, or hung
recorder is silent. A recorder still running after 10 seconds is stopped.
Unload, and V2 session deletion, wait up to two seconds for in-flight records
so the final `SessionEnd` lands, then stop or cancel the rest. A host that
exits without unloading the plugin stops, from its exit handler, any recorder
that has been running for over a second, with its process group. Younger
recorders are left to finish on their own, detached in their own process
group, so a host that exits right after a tool call still leaves that call's
record. The trade-off is that a recorder which wedges within its first second
before such an exit lingers until it ends by itself.

## OpenCode V2

V2 hooks are registered on the tool, shell, session, and permission domains.
The adapter translates native `shell` and edit/write `path` inputs, structured
shell results, and MCP inventory returned by `mcp.list`. Namespaced resource
helpers retain their canonical MCP identities; the combined V2 resource list
guards both resource and template operations for each contacted server. Unscoped
lists refuse incomplete inventories rather than guarding only a cached subset.
Denial still rejects
execution before the tool runs. MCP errors are delivered by the native
`execute.after` failure variant. Interrupted calls and failures retaining a
structured permission-denial cause skip execution post-hooks. OpenCode can wrap
MCP permission failures in an opaque `Tool.Error`; without that cause, the
adapter conservatively reports a failed MCP invocation, never a success.

Prompt and lifecycle guidance enters typed model system parts, without changing
user prompt text. Session locations and subpaths determine hook working
directories. The server event stream uses V2 data envelopes for Stop and
SessionEnd; unloading aborts the subscription, removes registrations, and drains
started session lifecycles.

A native background shell result marked `running` is admission, not completed
execution. Its pre-hook runs normally, but the adapter does not run a completion
post-hook for that partial result. Later output from `shell_read`/`shell_wait` is
not currently forwarded to the shell post-hook.

## Configuration

- `AGENTGUARD_OPENCODE_NAME` overrides the default `opencode` runtime identity
  for a protocol-compatible host.
- `AGENTGUARD_OPENCODE_TIMEOUT_SCALE` scales timeout budgets for tests. Normal
  installations should leave it unset.

Install the file in OpenCode's global plugin directory using a consumer-owned,
idempotent deployment step. Consumers should preserve unmanaged regular files
and symlinks and should treat a missing provider asset as a failed refresh, not
as an instruction to delete the last working plugin.

Run `test/suites/opencode-agentguard-test` for the adapter's behavioral suite.
The dedicated CI job loads the installed asset through pinned public V1 and V2
OpenCode releases, covering native discovery and callback boundaries in addition
to the direct behavioral suite.
