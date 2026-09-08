# AGENTS.md

## About

`agentguard` owns shared helpers and PATH-visible `agent-hook-*`
entry points. Hooks are agent-agnostic (Claude Code, Codex, Gemini
CLI, Grok, Muse, OpenCode, or another host that follows the same
protocol). AgentGuard never mutates an agent's configuration.

## Architecture

- `bin/agent-hook-*` are thin host-facing entry points: parse payload,
  call library policy, exit with the status the host expects.
- `lib/agentguard/` owns reusable policy. `hook-helpers.sh` is the
  hook-runtime API; `agentguard.sh` is the sourceable detection API
  for non-hook callers; `detect.sh` is internal.
- `bin/agentguard-classify-command` is the supported non-hook JSON
  classifier. Do not source private `_hook_*` classifier helpers from
  consumers.
- `share/agentguard/integrations/` holds policy-free native fragments
  (event names, matchers, timeouts, identity, hook commands).
  Consumers own activation and merging.
- Secure launcher and resolver text is generated from
  `support/secure-launcher.sh.template` and
  `support/script-resolver.sh.template`. After template edits, run
  `support/sync-hook-bootstrap`. `--check` rejects stale copies.

## Invariants

- Direct executable invocation through the privileged shebang is the
  supported security boundary. `HOME` and `PATH` never select the
  Bash interpreter. Explicit `bash script-path` is outside that
  boundary. See README for the loader-environment contract.
- Integration assets exclude permissions, models, MCP servers, UI
  settings, and machine policy.
- Muse gets the Codex-style `hookSpecificOutput.additionalContext`
  shape with no legacy `context` field and no `suppressOutput`.
- Tests assert machine behavior (exit status, contract JSON/text,
  filesystem effects), not incidental prose.

## Testing

CI shell job (ShellCheck is the shared inventory job):

```sh
AGENTGUARD_SKIP_SHELLCHECK=1 test/agentguard-test
```

Required extra job:

```sh
test/suites/opencode-agentguard-test
```

Local `test/agentguard-test` also ShellChecks runtime, example, and
tooling files. Set `AGENTGUARD_TEST_JOBS` to bound workers; hook
latency suites always run alone.
