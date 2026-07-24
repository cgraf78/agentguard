# AI Agent Hooks

`agentguard` owns shared helper code for `agent-hook-*` scripts. `shdeps`
installs the executable files in `bin/` as PATH-visible symlinks.
The hooks are agent-agnostic and work with Claude Code, Codex, Gemini CLI, or
another tool that follows the same hook protocol.

## Public API

- `agentguard.sh` is the sourceable detection API for scripts outside the hook
  runtime.
- `agentguard-classify-command` is the supported command-line API for non-hook
  consumers that need AgentGuard's command classifier output as structured JSON.
- `claude-session-name` is a PATH-visible helper used by
  `agent-hook-session-end-claude` to name Claude transcript sessions.
- `hook-helpers.sh` is the hook-runtime API for `agent-hook-*` entry points and
  sourced extensions.
  Sourced extensions can read `AGENTGUARD_CMD_TRIMMED`,
  `AGENTGUARD_CMD_LINE1`, `AGENTGUARD_EDIT_FILES`, and
  `AGENTGUARD_EDIT_FILE` after the matching parser helper runs.
- `detect.sh` is internal to those public entry points.
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

Use shdeps to locate sourceable files instead of reconstructing install paths:

```bash
. "$(shdeps dep-file cgraf78/agentguard lib/agentguard/agentguard.sh)"
```

## Dependencies

- Bash 4 or newer for hook scripts that use the command classifier. On macOS,
  `agent-hook-pre-bash` and `agentguard-classify-command` validate and re-exec
  `/opt/homebrew/bin/bash`, `/usr/local/bin/bash`, `/bin/bash`, or
  `/usr/bin/bash`, in that order, from a fixed privileged `/bin/bash -p`
  bootstrap. `HOME` and `PATH` never select the interpreter. Direct executable
  invocation through the privileged shebang is the supported security boundary,
  but it also requires a trusted or sanitized dynamic-loader environment. On
  Linux, this includes `LD_PRELOAD`, `LD_AUDIT`, and `LD_LIBRARY_PATH`; platform
  equivalents such as macOS `DYLD_INSERT_LIBRARIES`, `DYLD_LIBRARY_PATH`, and
  related `DYLD_*` controls must likewise be removed or trusted before process
  startup. The `-p` option changes Bash behavior only after the dynamic loader
  starts it; `-p` cannot protect before Bash loads. Explicit interpreter
  invocation such as `bash script-path` is outside this security boundary: Bash
  can run caller-controlled `BASH_ENV` code that changes or forges behavior
  before the script's first instruction, and no shell script can undo or reliably
  detect those earlier effects. Rejection of an otherwise ordinary, detectable
  explicit invocation is best-effort only, not a security guarantee. Before
  candidate discovery, `/usr/bin/awk` must return an exact
  clean or dirty environment sentinel. Raw exported-function entries trigger a
  clean `/bin/bash` environment rebuild: valid ordinary exported names and
  values travel as NUL-delimited records over the clean process's initial stdin,
  never as command-line operands, while `BASH_ENV`, `ENV`, recursion, POSIX and
  compatibility controls, shell-internal state, legacy re-entry markers, and
  every `BASH_FUNC_*%%` entry are excluded. `BASH_XTRACEFD` is made
  non-exported instead of unset so Bash cannot close its caller-owned target.
  Collision-free private descriptors below Bash's reserved fd 255 preserve
  caller stdin and stdout, including a closed stdin, while pre-source stdout
  carries the handshake; those descriptors close before application code runs.
  Exhausting that portable descriptor range fails closed.
  Each candidate proves Bash 4 semantics and sources the launcher in that same
  process with the original stdin, stdout, argv, and exit status. Both directly
  executed entry points exit with status 2 rather than continuing
  unguarded when no compatible Bash is available or a fixed inspection or
  scrub tool fails.
- `jq` for hook payload parsing and JSON responses.
- `cgraf78/sley` is a hard runtime dependency for hooks that format files.
  `agent-hook-post-edit` invokes the PATH-visible `sley hook format-file` CLI.
  Commit readiness belongs in native VCS hooks so human and agent workflows
  share one path.

Optional integrations are detected at runtime: `hm` enables Hive Memory hook
context when its config is available through `HIVE_MEMORY_CONFIG`, an absolute
`XDG_CONFIG_HOME`, or `~/.config`; `sl`, `git`, and `jj` enable repository
status context, and
`claude-templates` enables a Claude-specific maintenance hook when that
command is installed.

The launcher trusts the platform `/bin/bash -p`, `/usr/bin/awk`,
`/usr/bin/env`, and the absolute Bash candidate files above. The fixed
`/bin/bash` interpreter is the bootstrap trust anchor and must be a working
Bash. Candidate entry programs detect accidental non-Bash executables and
avoid a validate-then-reopen race, but cannot authenticate a deliberately
malicious file already installed at a trusted path. The `HOME` and `PATH`
variables cannot add candidate paths; normal PATH-visible hook dependencies
remain caller-trusted after bootstrap.

## Lifecycle

Base hooks follow the same shape:

```text
set -u
_HOOK_SELF="${AGENTGUARD_HOOK_SELF:-$0}"
_HOOK_BIN_DIR=$(_agentguard_script_dir "${BASH_SOURCE[0]}")
source "$_HOOK_BIN_DIR/../lib/agentguard/hook-helpers.sh"
# parse input and run base logic
_hook_source_extensions
_hook_finish
```

The secure pre-Bash bootstrap is generated into its two entry points from
`support/secure-launcher.sh.template`; the resolver block is generated into all
launchers from `support/script-resolver.sh.template`. Run
`support/sync-hook-bootstrap` after changing either template. Its `--check`
mode rejects a stale or one-sided generated edit.

The resolver cannot be loaded from `lib/` or a PATH command because it locates
`lib/` itself, and launchers may use a minimal PATH.

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

The state root itself is per-user, never a shared, predictable `/tmp`
directory: an absolute `$XDG_RUNTIME_DIR/agentguard/hook-state` when available
(a per-user directory the system clears on logout), falling back to an absolute
`$XDG_STATE_HOME`, then `~/.local/state`, and finally a uid-scoped tmp path only
when neither an absolute XDG root nor `HOME` is available. Relative XDG roots
are ignored as required by the XDG base-directory contract.

Launchers should set `AGENTGUARD_NAME` with `AGENTGUARD_SESSION_ID` when they know
the concrete agent. `AGENTGUARD_SESSION_ID` alone falls back to the generic
`agent` identity.

## Policy Reference

The root [README](../../README.md) is the canonical policy reference for adding
agents and for base hook behavior. Keep this library README focused on
sourceable APIs and lifecycle details so hook policy does not drift across two
documents.

## Script Notes

`claude-session-name` is a PATH-visible helper used by
`agent-hook-session-end-claude`. It can also name older transcripts in batch:

```text
claude-session-name <transcript_path>
```
