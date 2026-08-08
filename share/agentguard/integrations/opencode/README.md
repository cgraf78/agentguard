# OpenCode Integration

`agentguard.js` is the native OpenCode adapter for AgentGuard. OpenCode exposes
JavaScript plugin callbacks rather than a declarative hook table, so the adapter
translates those callbacks into the same payload contract consumed by the
PATH-visible `agent-hook-*` commands.

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
callback exports the same generic keys into OpenCode's actual shell tool so
other AgentGuard-aware tools can attribute child activity without the adapter
depending on their vocabulary.

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
The dedicated CI job also loads it through a pinned public OpenCode release and
proves that runtime invokes its real `config` callback, covering discovery and
one native callback boundary in addition to direct behavioral tests.
