# agentguard

![Tests](https://github.com/cgraf78/agentguard/actions/workflows/test.yml/badge.svg?branch=main)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Bash Version](https://img.shields.io/badge/bash-%3E%3D4.2-blue.svg)](https://www.gnu.org/software/bash/)
[![Platform](https://img.shields.io/badge/platform-Linux%20%7C%20macOS%20%7C%20WSL-lightgrey.svg)](#)

`agentguard` owns shared helper code and reusable entry points for
`agent-hook-*` scripts. `shdeps` installs the executable files in `bin/` as
PATH-visible symlinks.
The hooks are agent-agnostic and work with Claude Code, Codex, Gemini CLI, or
another tool that follows the same hook protocol.

## Public API

- `bin/agent-hook-*` files are the PATH-visible hook entry points.
- `bin/agentguard-classify-command` emits JSON command facts for non-hook
  policy audits that need AgentGuard's conservative shell command-word model.
- `bin/claude-session-name` names Claude transcript sessions for
  `agent-hook-session-end-claude` and for manual transcript backfills.
- `lib/agentguard/agentguard.sh` is the sourceable detection API for non-hook
  callers.
- `lib/agentguard/hook-helpers.sh` is the hook-runtime API used by hook entry
  points and hook extensions.
  Sourced extensions can read `AGENTGUARD_CMD_TRIMMED`,
  `AGENTGUARD_CMD_LINE1`, `AGENTGUARD_EDIT_FILES`, and
  `AGENTGUARD_EDIT_FILE` after the matching parser helper runs.
- `share/agentguard/shell.sh` is a stable no-op shell loader for integration
  harnesses that source each dependency's shell API uniformly.
- `agent-hook-pre-edit` warns after `AGENTGUARD_EDIT_CHURN_WARN` edits to a
  file and blocks after `AGENTGUARD_EDIT_CHURN_BLOCK` edits. Defaults are `5`
  and `10`. Set `AGENTGUARD_EDIT_CHURN_BYPASS=1` to bypass the churn warning
  and block for a deliberate edit pass.
- `agent-hook-pre-bash` can guard a broad bare-Git work tree when an integration
  sets `AGENTGUARD_PROTECTED_BARE_GIT_DIR`. Optional companion settings are
  `AGENTGUARD_PROTECTED_BARE_GIT_WORK_TREE` (defaults to `$HOME`),
  `AGENTGUARD_PROTECTED_BARE_GIT_ALIASES` (space-separated shell variable names
  that should resolve to the protected Git dir),
  `AGENTGUARD_PROTECTED_BARE_GIT_LAUNCHER` (the PATH-visible `git` wrapper to
  model), and the `AGENTGUARD_PROTECTED_BARE_GIT_{STATUS,LS_FILES,CLEAN}_MESSAGE`
  remediation strings.

Source non-binary assets through shdeps so install locations stay under the
dependency manager's contract:

```bash
. "$(shdeps dep-file cgraf78/agentguard lib/agentguard/agentguard.sh)"
```

## Dependencies

- Bash 4 or newer for hook scripts that use the command classifier. On macOS,
  `agent-hook-pre-bash` re-execs `~/.local/bin/bash`, Homebrew Bash, or
  `/usr/local/bin/bash` when `/usr/bin/env bash` resolves to Bash 3.
- `jq` for hook payload parsing and JSON responses.
- `cgraf78/sley` is a hard runtime dependency for hooks that format files.
  `agent-hook-post-edit` invokes the PATH-visible `sley hook format-file` CLI.
  Commit readiness belongs in native VCS hooks so human and agent workflows
  share one path.

Optional integrations are detected at runtime: `hm` enables Hive Memory hook
context, `sl`, `git`, and `jj` enable repository status context, and
`claude-templates` enables a Claude-specific maintenance hook when that
command is installed.

## Tests

Run `test/agentguard-test` to execute repo-owned hook suites. Behavioral
coverage for hook entry points lives here, including the protected bare-Git
guard that the command classifier exercises. Downstream consumers should keep
only install and wiring smoke tests. Consumers that need command detection
should call `agentguard-classify-command` rather than sourcing private
`_hook_*` classifier helpers.

## Lifecycle

Base hooks follow the same shape:

```text
set -u
_HOOK_SELF="${AGENTGUARD_HOOK_SELF:-$0}"
_HOOK_BIN_DIR=$(_hook_script_dir "${BASH_SOURCE[0]}")
source "$_HOOK_BIN_DIR/../lib/agentguard/hook-helpers.sh"
# parse input and run base logic
_hook_source_extensions
_hook_finish
```

`_hook_script_dir` (and its `_hook_script_parent` helper) is inlined into each
hook rather than shared from `lib/` or a PATH-visible command: it is what
*locates* `lib/`, and launchers sometimes invoke hooks with a minimal PATH (the
reason `agent-hook-pre-bash` re-execs a modern Bash), so the resolver must stay
self-contained and depend only on `BASH_SOURCE` + `readlink`.

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
- once markers: `_hook_prompt_cycle_reset`, `_hook_once_per_prompt`,
  `_hook_once_per_session`
- state helpers: `_hook_edit_churn_file`, `_hook_counter_read`,
  `_hook_counter_increment`, `_hook_counter_reset`
- target directory setup: `_hook_cd_to_target`
- extension loading: `_hook_source_agent`, `_hook_source_work`
- final JSON emission: `_hook_finish`

The per-session state directory is computed once at source time and refreshed
after hook JSON is read. A neutral `AGENTGUARD_SESSION_ID` wins when a launcher
supplies one. Managed Codex hooks prefer JSON `session_id` after stdin is
available, because nested Codex launches can inherit an outer
`CODEX_THREAD_ID`. Without JSON, Codex uses `CODEX_THREAD_ID` or its parent
process key, Claude uses `CLAUDE_CODE_CURRENT_SESSION_ID`, Gemini uses
`gemini-$PPID`, and unknown agents fall back to `$$`.

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
  `rm -rf` usage, and reminds agents to run a review/simplify pass and inspect
  the final diff before commit-class commands. Metadata-only changes skip the
  commit reminder.
- `agent-hook-post-bash` scans command stdout for high-confidence credential
  patterns. Stdout extraction is centralized so agent-specific payload names do
  not leak into the base hook.
- `agent-hook-pre-edit` parses edited paths, reminds once per user prompt on
  code/config edits to apply AGENTS.md design/workflow/code-style guidance plus
  any loaded language-specific rule fragments, warns or blocks repeated edits to
  the same file unless `AGENTGUARD_EDIT_CHURN_BYPASS` is enabled, and leaves
  room for environment-specific generated-file or readonly-file guards.
- `agent-hook-post-edit` formats changed files through
  `sley hook format-file`. Broader lint and verification policy stays in the
  native commit hooks.
- `agent-hook-pre-mcp` guards MCP calls: it blocks a server after repeated
  failures, warns on exact `search_files` leaf-tool calls without a path
  filter, and warns once on exact `knowledge_load` leaf-tool calls because
  large docs can consume significant context.
- `agent-hook-post-mcp` tracks MCP failure streaks for that circuit breaker.
- `agent-hook-session-start` detects repo type in `sl`, `git`, then `jj` order,
  reports uncommitted changes, warns on high disk usage, and injects Hive Memory
  startup context when `hm` is installed and configured.
- `agent-hook-session-end` parses session metadata for agent-specific naming or
  sync extensions.
- `agent-hook-prompt-submit` lets `hm hook prompt-submit` handle memory-intent
  reminders and context refresh decisions, then resets prompt-cycle state used
  by once-per-prompt guidance. The hook passes prompt text and path facts; it
  does not decide what should be written.
- `agent-hook-stop` asks Hive Memory for any pending-memory reminder, then plays
  terminal notifications. On Codex, only explicit reminders or blocks continue
  the turn; ordinary warnings do not trap shutdown. `agent-hook-notification`
  only plays notifications.

Hive Memory integration is deliberately centralized behind `hm hook <event>`.
The shell hooks pass only event facts: agent id, session id, and the best
available active path. Store affinity, project resolution, context freshness,
and refresh policy live in `hm`, so agent-specific or local extension files
do not need to duplicate memory policy. Normal `hm remember` and `hm note`
commands run through the dotfiles launcher, which adds active agent/session
environment so `hm` can write receipts and later clear pending-memory reminders
after a successful tool event.
When an agent session is launched from `$HOME`, AgentGuard treats that as "no
active project" rather than passing home as a project hint. Explicit file paths
under `$HOME` still pass through, so one long-lived session can work across many
projects without collapsing context onto the home directory itself.

Claude-specific extensions auto-name untitled sessions and run the daily
`claude-templates update` refresh in the background.

## Script Notes

`claude-session-name` is a PATH-visible helper used by
`agent-hook-session-end-claude`. It can also name older transcripts in batch:

```text
claude-session-name <transcript_path>
```

## License

MIT. See [`LICENSE`](LICENSE).
