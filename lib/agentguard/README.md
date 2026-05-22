# AI Agent Hooks

`agentguard` owns shared helper code for `agent-hook-*` scripts. `shdeps`
installs the executable files in `bin/` as PATH-visible symlinks.
The hooks are agent-agnostic and work with Claude Code, Codex, Gemini CLI, or
another tool that follows the same hook protocol.

## Public API

- `agentguard.sh` is the sourceable detection API for scripts outside the hook
  runtime.
- `hook-helpers.sh` is the hook-runtime API for `agent-hook-*` entry points and
  sourced extensions.
- `detect.sh` is internal to those public entry points.
- `agent-hook-pre-bash` can guard a broad bare-Git work tree when an integration
  sets `AGENTGUARD_PROTECTED_BARE_GIT_DIR`. Optional companion settings are
  `AGENTGUARD_PROTECTED_BARE_GIT_WORK_TREE` (defaults to `$HOME`),
  `AGENTGUARD_PROTECTED_BARE_GIT_ALIASES` (space-separated shell variable names
  that should resolve to the protected Git dir),
  `AGENTGUARD_PROTECTED_BARE_GIT_LAUNCHER` (the PATH-visible `git` wrapper to
  model), and the `AGENTGUARD_PROTECTED_BARE_GIT_{STATUS,LS_FILES,CLEAN}_MESSAGE`
  remediation strings.

Use shdeps to locate sourceable files instead of reconstructing install paths:

```bash
. "$(shdeps dep-file cgraf78/agentguard lib/agentguard/agentguard.sh)"
```

## Dependencies

- Bash 4 or newer for hook scripts that use the command classifier. On macOS,
  `agent-hook-pre-bash` re-execs `~/.local/bin/bash`, Homebrew Bash, or
  `/usr/local/bin/bash` when `/usr/bin/env bash` resolves to Bash 3.
- `jq` for hook payload parsing and JSON responses.
- `cgraf78/sley` is a hard runtime dependency for hooks that format files or
  gate commits. `agent-hook-post-edit` invokes the PATH-visible
  `sley hook format-file` CLI, and `agent-hook-pre-bash` invokes
  `sley ready --fix --quiet --commit` for the pre-commit readiness gate. If the
  `sley` command is missing when one of those hook paths needs it, Agentguard
  blocks loudly instead of silently skipping the policy.

Optional integrations are detected at runtime: `hm` enables Hive Memory hook
context, `sl`, `git`, and `jj` enable repository status context, and
`claude-templates` or `sync-memory` enable Claude-specific maintenance hooks
when those commands are installed.

## Lifecycle

Base hooks follow the same shape:

```text
set -u
_HOOK_SELF="$0"
_HOOK_BIN_DIR=$(resolve-real-script-dir "$BASH_SOURCE")
source "$_HOOK_BIN_DIR/../lib/agentguard/hook-helpers.sh"
# parse input and run base logic
_hook_source_extensions
_hook_finish
```

The split between `_HOOK_SELF` and `_HOOK_BIN_DIR` is intentional: `_HOOK_SELF`
keeps extension discovery adjacent to the invoked symlink in `~/.local/bin`,
while `_HOOK_BIN_DIR` resolves through that symlink to load dependency libraries.

Extension scripts are sourced, not executed:

- `-claude`, `-codex`, and `-gemini` files are selected from agent-specific
  environment variables.
- `-work` files are environment-specific overlays.

Each hook emits one JSON response through `_hook_finish`.

## Shared Helpers

`hook-helpers.sh` provides:

- accumulators: `_hook_block`, `_hook_warn`, `_hook_remind`, `_hook_context`
  (`_hook_warn` and `_hook_remind` also add model-visible hook context; use
  `_hook_context` directly for context that should not appear as a warning or
  reminder in stderr)
- parsers: `_hook_parse_command`, `_hook_parse_mcp`
- tool payload adapters: `_hook_tool_stdout`
- Hive Memory adapters: `_hook_hm_session_start`, `_hook_hm_prompt_submit`,
  `_hook_hm_tool_complete`, `_hook_hm_stop`
- target directory setup: `_hook_cd_to_target`
- extension loading: `_hook_source_agent`, `_hook_source_work`
- final JSON emission: `_hook_finish`

The per-session state directory is computed once at source time. A neutral
`AGENTGUARD_SESSION_ID` wins when a launcher supplies one. Otherwise, runtime
session ids are preferred when available: Codex uses `CODEX_THREAD_ID`, Claude
uses `CLAUDE_CODE_CURRENT_SESSION_ID`, Gemini uses `gemini-$PPID`, and unknown
agents fall back to `$$`.

Launchers should set `AGENTGUARD_NAME` with `AGENTGUARD_SESSION_ID` when they know
the concrete agent. `AGENTGUARD_SESSION_ID` alone falls back to the generic
`agent` identity.

## Adding an Agent

To add a new managed agent runtime:

- add a consumer-owned config generator or source layer that emits the agent's
  native config format
- make every managed hook command set `AGENTGUARD_NAME=<agent>` and
  `AGENTGUARD_SESSION_ID=<stable-id-or-empty>`
- map the agent's hook payload schema into the shared `agent-hook-*` scripts
  instead of adding policy directly to the agent config
- add `-<agent>` extension scripts only for behavior that is truly
  runtime-specific
- update `detect.sh` only when the runtime exposes reliable process or
  environment signals
- add tests that verify hook env injection, session identity, payload parsing,
  and Hive Memory attribution
- if the agent supports skills or extensions, update the gstack registration
  helper or document why it is unsupported

## Base Hook Policy

- `agent-hook-pre-bash` blocks destructive `rm -rf` targets, warns on other
  `rm -rf` usage, and reminds agents to review and test before commit-class
  commands. Metadata-only changes skip the commit reminder.
- `agent-hook-post-bash` scans command stdout for high-confidence credential
  patterns. Stdout extraction is centralized so agent-specific payload names do
  not leak into the base hook.
- `agent-hook-pre-edit` parses the target file path and leaves base behavior
  empty for environment-specific generated-file or readonly-file guards.
- `agent-hook-post-edit` formats changed files through
  `sley hook format-file`. Broader lint and verification policy stays in the
  commit gate.
- `agent-hook-pre-mcp` guards MCP calls: it blocks a server after repeated
  failures, warns on broad `search_files` calls without a path filter, and
  warns on `knowledge_load` because large docs can consume significant context.
- `agent-hook-post-mcp` tracks MCP failure streaks for that circuit breaker.
- `agent-hook-session-start` detects repo type in `sl`, `git`, then `jj` order,
  reports uncommitted changes, warns on high disk usage, and injects Hive Memory
  startup context when `hm` is installed and configured.
- `agent-hook-session-end` parses session metadata for agent-specific naming or
  sync extensions.
- `agent-hook-prompt-submit` lets `hm hook prompt-submit` handle memory-intent
  reminders and context refresh decisions.
- `agent-hook-stop` asks Hive Memory for any pending-memory reminder, then plays
  terminal notifications. `agent-hook-notification` only plays notifications.

Hive Memory integration is deliberately centralized behind `hm hook <event>`.
The shell hooks pass only event facts: agent id, session id, and the best
available active path. Store affinity, project resolution, context freshness,
and refresh policy live in `hm`, so agent-specific or local extension files
do not need to duplicate memory policy.

Claude-specific extensions auto-name untitled sessions, sync Claude memory on
stop, and run the daily `claude-templates update` refresh in the background.

## Script Notes

`claude-session-name` is a standalone helper used by
`agent-hook-session-end-claude`. It can also name older transcripts in batch:

```text
claude-session-name <transcript_path>
```
