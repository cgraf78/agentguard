# agentguard

![Tests](https://github.com/cgraf78/agentguard/actions/workflows/test.yml/badge.svg?branch=main)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Bash Version](https://img.shields.io/badge/bash-%3E%3D4.2-blue.svg)](https://www.gnu.org/software/bash/)
[![Platform](https://img.shields.io/badge/platform-Linux%20%7C%20macOS%20%7C%20WSL-lightgrey.svg)](#)

`agentguard` owns shared helper code and reusable entry points for
`agent-hook-*` scripts. `shdeps` installs the executable files in `bin/` as
PATH-visible symlinks.
The hooks are agent-agnostic and work with Claude Code, Codex, Gemini CLI,
Muse, or another tool that follows the same hook protocol.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/cgraf78/agentguard/main/install.sh | bash
```

This keeps a durable managed checkout under `$XDG_DATA_HOME` when that path is
absolute, or under `$HOME/.local/share` otherwise, and publishes links to its
commands and manual pages. Rerunning the curl command safely updates the clean
managed checkout before republishing the links.

To choose and manage the checkout yourself instead, keep it at a stable path
and run:

```bash
./install.sh
```

The installer creates checkout-backed symlinks for every public command under
`$HOME/.local/bin` and for each matching manual page under
`$HOME/.local/share/man/man1`. Set `PREFIX` to relocate both trees, or set
`BIN_DIR` and `MAN_DIR` independently. Re-running the installer is safe and
retargets existing symlinks, but it refuses to replace a non-symlink path.
Moving or deleting the checkout breaks the installed links.

The direct command links preserve AgentGuard's secure-launcher boundary and
allow consumer hook extensions to remain adjacent to the invoked links. The
installer deliberately leaves `lib/agentguard/` and `share/agentguard/` in the
checkout and creates no completion tree. Continue to resolve those non-binary
assets through shdeps, or use their absolute paths in this checkout.

## Public API

- `bin/agent-hook-*` files are the PATH-visible hook entry points.
- `bin/agentguard-classify-command` emits JSON command facts for non-hook
  policy audits that need AgentGuard's conservative shell command-word model.
- `bin/claude-session-name` names Claude transcript sessions for
  `agent-hook-session-end-claude` and for manual transcript backfills.
- `lib/agentguard/agentguard.sh` is the sourceable detection API for non-hook
  callers. It exposes `agentguard_is_session`, `agentguard_agent_name`, and
  `agentguard_session_id` so launchers share one runtime-identity contract.
- `lib/agentguard/hook-helpers.sh` is the hook-runtime API used by hook entry
  points and hook extensions.
  Sourced extensions can read `AGENTGUARD_CMD_TRIMMED`,
  `AGENTGUARD_CMD_LINE1`, `AGENTGUARD_EDIT_FILES`, and
  `AGENTGUARD_EDIT_FILE` after the matching parser helper runs.
- `share/agentguard/shell.sh` is a stable no-op shell loader for integration
  harnesses that source each dependency's shell API uniformly.
- `share/agentguard/integrations/` contains canonical native hook fragments for
  Claude Code, Codex, Gemini CLI, and Muse, plus the OpenCode runtime adapter.
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
  model), and the
  `AGENTGUARD_PROTECTED_BARE_GIT_{STATUS,LS_FILES,CLEAN,ADD}_MESSAGE`
  remediation strings. The guard covers unscoped `status`, `ls-files`, `clean`,
  and whole-tree `git add` (`-A`, `.`, `:/`, globs); `git add` accepts explicit
  paths without a `--` separator, and `git add -u` is allowed because it
  restages tracked files only.

Source non-binary assets through shdeps so install locations stay under the
dependency manager's contract:

```bash
. "$(shdeps dep-file cgraf78/agentguard lib/agentguard/agentguard.sh)"
```

`agentguard_session_id [fallback_namespace]` prints a caller-supplied
`AGENTGUARD_SESSION_ID` first, then a native runtime id when one is available.
For detected runtimes without a native id it returns a namespaced
parent-process fallback, which is stable for the direct-call lifetime. The
optional namespace labels only a generic fallback; native ids and
runtime-specific fallbacks still win. With neither a detected runtime nor a
caller namespace, an ordinary human shell returns status 1 and prints nothing.
Hook entry points additionally have JSON payloads and therefore use their
JSON-aware session-state layer in `hook-helpers.sh`.

## Native Agent Integrations

AgentGuard publishes native, policy-free integration assets:

| Runtime | Asset |
| --- | --- |
| Shared lifecycle | `share/agentguard/integrations/_shared/reconcile-hooks.jq` |
| Claude Code | `share/agentguard/integrations/claude/hooks.json` |
| Codex | `share/agentguard/integrations/codex/hooks.toml` |
| Gemini CLI | `share/agentguard/integrations/gemini/hooks.json` |
| Muse | `share/agentguard/integrations/muse/hooks.json` |
| OpenCode | `share/agentguard/integrations/opencode/agentguard.js` |

The declarative fragments contain only AgentGuard hook activation: native event
names and matchers, timeouts, runtime identity, session identity, and hook
commands. They intentionally exclude permissions, models, MCP servers, UI
settings, and machine policy. Consumers choose whether to enable an integration
and remain responsible for merging or installing the asset without overwriting
unmanaged configuration. AgentGuard never mutates an agent's configuration.
Declarative consumers should apply the shared reconciler so the current
provider generation can replace changed commands and retire events while
preserving user hooks and runtime-owned state.

The OpenCode adapter translates OpenCode's plugin callbacks into AgentGuard's
shared hook schema. `AGENTGUARD_OPENCODE_NAME` can override the default
`opencode` identity for a compatible runtime, and
`AGENTGUARD_OPENCODE_TIMEOUT_SCALE` scales hook timeouts for tests. Hook
executables are invoked directly with shell startup controls removed so their
documented launcher boundary remains intact.

## Examples

[`examples/`](examples/) contains a neutral environment-policy hook extension
and complete reconciliation fixtures with expected output. Repo tests load the
extension through the real pre-Bash hook, execute the provider-owned `jq`
filter, compare its output, and prove a second reconciliation is unchanged.

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
- OpenCode supplies the Node.js runtime for its adapter. On POSIX systems, the
  adapter uses Python 3 and `ps` when available to sweep an entire timed-out
  process session. Python runs in isolated mode from a neutral directory;
  direct process-group cleanup remains the fallback.
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

The launcher trust boundary includes the platform `/bin/bash -p`,
`/usr/bin/awk`, `/usr/bin/env`, and the absolute Bash candidate files above.
The fixed `/bin/bash` interpreter is the bootstrap trust anchor and must be a
working Bash. Candidate entry programs reject accidental non-Bash executables
and avoid a validate-then-reopen race, but they cannot authenticate a
deliberately malicious file already installed at a trusted path. The `HOME`
and `PATH` variables cannot add candidate paths. After bootstrap,
PATH-visible dependencies such as `jq` and optional integration CLIs remain
caller-trusted.

## Tests

Run `test/agentguard-test` to execute repo-owned hook suites. Behavioral
coverage for hook entry points lives here, including the protected bare-Git
guard that the command classifier exercises. Downstream consumers should keep
only install and wiring smoke tests. Consumers that need command detection
should call `agentguard-classify-command` rather than sourcing private
`_hook_*` classifier helpers. Independent suites use four workers by default;
set `AGENTGUARD_TEST_JOBS` to a positive integer to tune that bound for a
specific host. Hook latency budgets always run alone.

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
`support/secure-launcher.sh.template`. `_agentguard_script_dir` (and its
`_agentguard_script_parent` helper) is generated into every launcher from
`support/script-resolver.sh.template`. The resolver cannot be loaded from `lib/`
or a PATH-visible command because it is what *locates* `lib/`, and launchers
sometimes invoke hooks with a minimal PATH (the reason `agent-hook-pre-bash`
re-execs a modern Bash). Run `support/sync-hook-bootstrap` after editing the
templates; the test entrypoint runs `--check` against the authoritative launcher
manifest to prevent missing or stale copies.

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

## Adding an Agent

To add a new managed agent runtime:

- add a canonical, policy-free native fragment or runtime adapter under
  `share/agentguard/integrations/`
- make every managed hook command set `AGENTGUARD_NAME=<agent>` and
  `AGENTGUARD_SESSION_ID=<stable-id-or-empty>`
- map the agent's hook payload schema into the shared `agent-hook-*` scripts
  instead of adding policy directly to the agent config
- add `-<agent>` extension scripts only for behavior that is truly
  runtime-specific
- update `detect.sh` only when the runtime exposes reliable process or
  environment signals
- add tests that verify native event mapping, hook environment injection,
  session identity, payload parsing, and referenced hook executables
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
- `agent-hook-stop` asks Hive Memory for any pending-memory reminder and plays a
  terminal notification for the first non-reentrant Stop callback after a valid
  prompt. Repeated callbacks stay silent until another valid prompt re-arms the
  shared AgentGuard state. Codex Stop continuations are currently suppressed
  because affected Codex releases persist their synthetic messages with
  replay-invalid item IDs; prompt-submit still surfaces memory reminders before
  Stop.
  `agent-hook-notification` plays notifications for host attention events such
  as permission requests.

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
