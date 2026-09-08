# Grok Integration

`hooks.json` is AgentGuard's complete hook-only Grok settings fragment. Grok
discovers global hooks from `~/.grok/hooks/*.json` and uses Claude-compatible
lifecycle names, with camelCase stdin envelopes (`sessionId`, `toolName`,
`toolInput`) and Grok-native tool names (`run_terminal_command`,
`search_replace`, qualified `server__tool` MCP calls).

This fragment owns Grok's lifecycle events, tool matchers, timeout budgets,
hook commands, and session-identity wiring. Matchers include both Claude-style
aliases (Grok maps `Bash` to `run_terminal_command` and `Edit`/`Write` to
`search_replace`) and Grok-native names so a matcher still fires if alias
expansion is disabled. MCP uses `mcp__|.+__` because Grok's real tool name is
the qualified `server__tool` id, not Claude's `mcp__` prefix.

Grok reports failed tool calls on `PostToolUseFailure` rather than
`PostToolUse`, so MCP circuit-breaker tracking is wired to that event as well
as successful post-tool MCP calls. Grok SessionStart does not fire for
subagent sessions, so `SubagentStart` runs the same `agent-hook-session-start`
command and `SubagentStop` reuses `agent-hook-stop`. Grok Stop and
SubagentStop `additionalContext` keep the agent working, so both stay
fail-open empty JSON instead of injecting Hive Memory context.

Child events carry camelCase `subagentType` (and sometimes a distinct JSON
`sessionId`). Hook state is then keyed as `${GROK_SESSION_ID}:${subagentType}`
or that child session id so overlapping children do not share circuit-breaker
or Hive Memory markers with the parent. Parent SessionStart/Stop omit
`subagentType` and keep the unsuffixed `GROK_SESSION_ID` key.

The fragment contains no permission rules, models, MCP servers, or other user
settings. Consume it with `../_shared/reconcile-hooks.jq` as one
provider-owned generation, then put personal or machine policy in a separate
later layer or a sibling `~/.grok/hooks/*.json` file. If either asset cannot
be refreshed, preserve the complete last valid settings target rather than
treating dependency failure as an explicit opt-out.

`GROK_SESSION_ID` is injected on every Grok hook process. Direct child
processes without that variable fall back to process-tree detection of the
`grok` binary (not the installer-linked `agent` name) and to `grok-$PPID`.

The exact native contract is validated by
`test/suites/integration-assets-test`. Change event mappings here and in that
test together; downstream consumers should test only their merge mechanics.
