#!/usr/bin/env bash
# hook-helpers.sh — shared helpers for AI agent hook scripts.
# Source at the top of every hook. Provides accumulators for blocks,
# warnings, and context, plus work-variant sourcing and final emission.
# Agent-agnostic: works with Claude Code, Codex, Gemini CLI, Muse, Grok, or any
# agent that follows the same hook protocol (JSON on stdout, exit 2
# to block).
#
# Every base hook follows the same lifecycle:
#   source helpers → base logic → _hook_source_extensions → _hook_finish
# Order is most-general to most-specific: base (universal) → agent
# (Claude/Codex/Gemini/Muse/Grok specific) → work (environment specific) → emit + exit.

# --- State (computed once at source time, no subshells) ---

_HOOK_BLOCKED=''
_HOOK_CTX=''
_HOOK_HM_CONFIG_PATH=''
# Hive Memory delivery tracking for this hook (see _hook_hm_delivery_policy):
# optional `hm hook` arguments, the host's context lifetime and size limit, the
# last hm status, and where the memory context sits in _HOOK_CTX so
# _hook_finish can verify it against the host limit.
_HOOK_HM_DELIVERY_ARGS=()
_HOOK_HM_TRACKED=''
_HOOK_HM_LIFETIME=''
_HOOK_HM_LIMIT_KIND=''
_HOOK_HM_LIMIT=''
_HOOK_HM_EVENT=''
_HOOK_HM_EVENT_NAME=''
_HOOK_HM_LAST_RC=0
_HOOK_HM_RESPONSE=''
_HOOK_HM_CTX_PREFIX=''
_HOOK_HM_CTX_BODY=''
_HOOK_HM_QUIET=''
_HOOK_HM_POLICY_AGENT=''
_HOOK_INPUT_STATE_REFRESHED=''
_HOOK_INPUT_SESSION=''
_HOOK_INPUT_EVENT=''
# Set once this process has tried to read stdin, so the telemetry trap does not
# wait on an empty or held-open pipe a second time.
_HOOK_INPUT_ATTEMPTED=''
_HOOK_PROMPT_SUBMITTED=''
# Cached _hook_stop_is_foreground answer (1 or 0); a Stop hook asks twice.
_HOOK_STOP_FOREGROUND=''
# Set while a Stop hook has not yet settled whether its turn ends; see
# _hook_stop_arm.
_HOOK_STOP_PENDING=''
# Telemetry accumulators: block/warn/remind messages joined by ASCII record
# separators so multi-line messages survive intact into the audit record.
_HOOK_TELEMETRY_BLOCKS=''
_HOOK_TELEMETRY_WARNINGS=''
_HOOK_TELEMETRY_REMINDERS=''
# Set by _hook_finish once it has written the response, so the exit trap only
# supplies one when a hook died before reaching it.
_HOOK_EMITTED=''
# Fail-closed state for guard hooks; see _hook_exit.
_HOOK_FAIL_CLOSED=''
_HOOK_STDERR_FILE=''
_HOOK_STDERR_FD=''

# --- Fail-closed exit handling ---
#
# Hosts block a tool call only when a PreToolUse hook exits 2 (OpenCode's
# adapter rejects any nonzero exit). Every other status, including Bash's 127
# for an unbound variable under `set -u` or 1 for a failed builtin, is a
# "non-blocking hook error": the tool runs with every guard skipped. Guard
# hooks therefore treat any unexpected exit, or any Bash runtime error that a
# command substitution swallowed, as a block.
#
# Advisory hooks (PostToolUse, lifecycle, prompt, Stop, notification) keep
# their status. They cannot undo a completed call, and turning their failures
# into exit 2 would block the user's prompt or re-enter the agent loop on
# Stop. This matches the OpenCode adapter's documented failure semantics.

# Bash runtime errors that mean AgentGuard's own code misbehaved. Bash prints
# `<file>: line <n>: <message>`; only files AgentGuard ships count (see
# _hook_stderr_line_is_internal_error), so a consumer extension's noise or a
# missing optional tool (`sl: command not found`) cannot block every command.
_hook_bash_error_is_internal() {
  case "$1" in
    *"unbound variable" | *"bad array subscript" | *"bad substitution" | \
      *"syntax error"* | *"invalid arithmetic operator"* | *"division by 0"* | \
      *"value too great for base"* | *"integer expression expected" | \
      *"unary operator expected" | *"binary operator expected" | \
      *"too many arguments" | *"not a valid identifier" | \
      *"invalid variable name" | *"maximum function nesting level exceeded"* | \
      *"readonly variable" | *"ambiguous redirect")
      return 0
      ;;
    # A missing private helper means a broken or partial install; external
    # tools never use the leading underscore.
    _*": command not found")
      return 0
      ;;
  esac
  return 1
}

_hook_stderr_line_is_internal_error() {
  local line="$1" source base
  [[ "$line" =~ ^(.*):\ line\ [0-9]+:\ (.*)$ ]] || return 1
  source="${BASH_REMATCH[1]}"
  _hook_bash_error_is_internal "${BASH_REMATCH[2]}" || return 1
  base="${source##*/}"
  [ -n "$base" ] || return 1
  # Match by basename: Bash names a sourced file by the path it was sourced
  # through (`bin/../lib/...`). The hook itself and its library modules count;
  # `<hook>-<agent>` and `<hook>-work` extensions do not, even when one sits
  # in the same directory as the hook.
  [ "$base" = "${_HOOK_SELF##*/}" ] && return 0
  case "$base" in
    *.sh) [ -e "${_AGENTGUARD_LIB_DIR:-/nonexistent}/$base" ] && return 0 ;;
  esac
  return 1
}

# Route this guard hook's stderr through a private file so _hook_exit can see
# Bash runtime errors raised inside command substitutions. Those subshells
# exit nonzero, their callers read that as "no match", and the guard would
# silently allow. Capture is best-effort: when the state root is unwritable
# the hook keeps its real stderr and still fails closed on its exit status.
_hook_capture_stderr() {
  local dir file
  [ -n "$_HOOK_FAIL_CLOSED" ] || return 0
  [ -z "$_HOOK_STDERR_FILE" ] || return 0
  dir="${_HOOK_STATE_DIR%/*}-stderr"
  [ -d "$dir" ] || _hook_mkstate "$dir" || return 0
  file="$dir/$$.${RANDOM}${RANDOM}"
  # Named descriptors (`exec {var}>&2`) are Bash 4.1+. The `env bash` hooks
  # can run under macOS /bin/bash 3.2, where that exec would fail and trip the
  # fail-closed trap on every call, and a fixed number would clobber a caller's
  # descriptor. Skip the best-effort capture there; the exit status still
  # fails closed.
  if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 1))); then
    return 0
  fi
  exec {_HOOK_STDERR_FD}>&2 || return 0
  # Open the file on a spare descriptor first, then move stderr onto that
  # same open file, so it is never reopened by name. noclobber makes the
  # open exclusive: a planted file or symlink at this name is refused
  # instead of followed. The group silences only the open's diagnostic and
  # restores fd 2 afterwards; the spare descriptor stays open. A bare
  # `exec 2>"$file"` would print a failure on the real stderr, and a sandbox
  # that keeps the dir but denies creates in it (Grok's Landlock workspace
  # profile vs. $XDG_RUNTIME_DIR) would show that line ahead of the block
  # reason. A caller's own noclobber setting is kept.
  local capture_fd noclobber=''
  case $- in *C*) noclobber=1 ;; esac
  set -C
  if { exec {capture_fd}>"$file"; } 2>/dev/null; then
    exec 2>&"$capture_fd" {capture_fd}>&-
    _HOOK_STDERR_FILE="$file"
  else
    exec {_HOOK_STDERR_FD}>&-
    _HOOK_STDERR_FD=''
    # Near the descriptor limit Bash creates the file and then fails to
    # allocate the spare descriptor, so a failed open can still leave an
    # orphan. Unlinking never follows a planted symlink at this name.
    rm -f -- "$file" 2>/dev/null
  fi
  [ -n "$noclobber" ] || set +C
}

# Restore the real stderr, replay what the hook wrote, and report whether any
# line was an internal Bash error. Replay keeps block reasons and warnings
# reaching the host unchanged; they are only delayed until exit.
_hook_release_stderr() {
  local file="$_HOOK_STDERR_FILE" line found=1
  [ -n "$file" ] || return 1
  _HOOK_STDERR_FILE=''
  exec 2>&"$_HOOK_STDERR_FD" {_HOOK_STDERR_FD}>&-
  _HOOK_STDERR_FD=''
  if [ -f "$file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      printf '%s\n' "$line" >&2
      _hook_stderr_line_is_internal_error "$line" && found=0
    done <"$file"
  fi
  rm -f -- "$file" 2>/dev/null
  return "$found"
}

# EXIT trap for every agent-hook-* entry point. The fail-closed verdict comes
# first and touches nothing that can fail fatally; telemetry then runs in a
# subshell because a fatal error inside an EXIT trap replaces the exit status,
# which would turn a block back into a non-blocking error.
_hook_exit() {
  local status=$? internal=''
  if _hook_release_stderr; then
    internal="a Bash runtime error"
  fi
  if [ -n "$_HOOK_FAIL_CLOSED" ]; then
    case "$status" in
      0 | 2) ;;
      *) internal="${internal:+$internal and }exit status $status" ;;
    esac
    if [ -n "$internal" ]; then
      status=2
      _HOOK_BLOCKED=1
      printf 'BLOCKED: AgentGuard internal error in %s (%s); refusing to run the tool call unguarded. Report this as an AgentGuard bug.\n' \
        "${_HOOK_SELF##*/}" "$internal" >&2
      _HOOK_TELEMETRY_BLOCKS+="${_HOOK_TELEMETRY_BLOCKS:+$'\x1e'}AgentGuard internal error ($internal)"
      [ -n "$_HOOK_EMITTED" ] || printf '{}\n'
    fi
  fi
  if [ -n "$_HOOK_STOP_PENDING" ]; then
    # A Stop that died before settling (a crashed, exiting, or signalled
    # extension) still ends the turn unless _hook_finish emitted a block.
    # Subshell for the same reason as telemetry: never replace the status.
    (_hook_stop_settle_exit) >/dev/null 2>&1
  fi
  if declare -F _hook_telemetry_exit >/dev/null; then
    (_hook_telemetry_exit "$status") 2>/dev/null
  fi
  exit "$status"
}

# Single front door for "this guard cannot do its job": block with a clear
# reason and emit the response now.
_hook_fail_closed() {
  _hook_block "AgentGuard internal error: $1; refusing to run the tool call unguarded."
  _hook_finish
}

case "${_HOOK_SELF:-$0}" in
  agent-hook-* | */agent-hook-*)
    # Installed before the rest of this library runs so a crash while it
    # initializes is still caught.
    case "${_HOOK_SELF:-$0}" in
      agent-hook-pre-* | */agent-hook-pre-*) _HOOK_FAIL_CLOSED=1 ;;
    esac
    trap _hook_exit EXIT
    ;;
esac

# General non-interactive shells get env.d through BASH_ENV/.zshenv. This is a
# hook-local fallback for launchers that invoke hook scripts by absolute path
# with a sparse environment. Avoid external commands until PATH is repaired;
# a trailing `:` would add the current directory to command lookup.
if [ -n "${PATH:-}" ]; then
  if [ -n "${HOME:-}" ] && [ -d "$HOME/.local/bin" ]; then
    case ":$PATH:" in
      *":$HOME/.local/bin:"*) ;;
      *) PATH="$HOME/.local/bin:$PATH" ;;
    esac
  fi
else
  PATH="/usr/local/bin:/usr/bin:/bin"
  if [ -n "${HOME:-}" ] && [ -d "$HOME/.local/bin" ]; then
    PATH="$HOME/.local/bin:$PATH"
  fi
fi
export PATH

_agentguard_lib_source="${BASH_SOURCE[0]}"
_AGENTGUARD_LIB_DIR="${_agentguard_lib_source%/*}"
if [ "$_AGENTGUARD_LIB_DIR" = "$_agentguard_lib_source" ]; then
  _AGENTGUARD_LIB_DIR='.'
fi
_AGENTGUARD_LIB_DIR="$(cd -- "$_AGENTGUARD_LIB_DIR" && pwd -P)"
unset _agentguard_lib_source

# Resolve sibling helpers from this dependency directory. Hook tests commonly
# mock HOME, but helper-to-helper dependencies should follow the library file
# that was actually sourced so partial test homes do not need a second copy.
# shellcheck source=detect.sh
# shellcheck disable=SC1091 # sibling module resolved from this file's dir.
source "$_AGENTGUARD_LIB_DIR/detect.sh"
# shellcheck source=telemetry.sh
# shellcheck disable=SC1091 # sibling module resolved from this file's dir.
source "$_AGENTGUARD_LIB_DIR/telemetry.sh"
# Captured as early as possible so a record's duration covers session
# resolution and payload parsing, not just the hook's policy logic.
_agentguard_telemetry_now_us _HOOK_TELEMETRY_START_US

# Return a stable Codex session key when Codex does not hand hooks a runtime
# session id. Codex launches hook scripts as short-lived child processes, so $$
# changes on every hook and is not suitable for per-session state such as
# "already injected Hive Memory context". Managed Codex configs set
# AGENTGUARD_NAME=codex, which lets us use process ancestry intentionally; for
# unmanaged environments, keep process-name probing opt-out capable so a random
# parent command containing "codex" cannot silently claim the hook.
_hook_codex_process_key() {
  case "${AGENTGUARD_NAME:-}" in
    codex) ;;
    claude | gemini | grok) return 1 ;;
    *)
      [ -n "${CODEX_THREAD_ID:-}" ] || [ "${CODEX_INTERNAL_ORIGINATOR_OVERRIDE:-}" = "codex" ] ||
        [ "${AGENTGUARD_PROCESS_DETECT:-1}" != "0" ] || return 1
      ;;
  esac

  local saw_codex=''
  saw_codex=$(_agent_codex_process_pid 2>/dev/null || true)

  if [ -n "$saw_codex" ]; then
    printf 'codex-%s\n' "$saw_codex"
  elif [ "${AGENTGUARD_NAME:-}" = "codex" ]; then
    # Explicitly managed Codex hooks are allowed to fall back to the immediate
    # parent if argv inspection cannot see a `codex` binary. This keeps tests,
    # packaged launchers, and future process names stable without forcing every
    # hook runner to expose a Codex-specific session variable.
    printf 'codex-%s\n' "$PPID"
  else
    return 1
  fi
}

# Per-user root for hook session state. Session markers, counters, and edit
# churn tracking are ephemeral and per-user; they must never live under a
# shared, predictable /tmp path. A fixed name like /tmp/hook-state lets another
# user on a shared host pre-create it (as a dir they own, or a symlink) and then
# tamper with another session's guard state, deny writes, or redirect them into
# a victim's tree (CWE-377/CWE-59). Prefer an absolute XDG_RUNTIME_DIR: a
# per-user 0700 directory the system wipes on logout, which is the canonical
# home for ephemeral runtime state and keeps stale per-session dirs from
# accumulating. Fall back to an absolute XDG_STATE_HOME, then ~/.local/state,
# and only to a uid-scoped tmp path when neither an XDG root nor HOME is
# available, so hooks never hard-fail. Threat model: HOME-present
# deployments are supported; the tmp fallback has no ownership/symlink
# validation (pre-existing hardening follow-up).
#
# A tier is used only if this process can write it. A sandboxed runtime can
# deny writes to a tier that exists and looks writable: Grok's Landlock
# workspace profile denies $XDG_RUNTIME_DIR while hooks still see it set, and
# Landlock does not restrict access(2), so `test -w` passes there. Each
# candidate is therefore probed with a real write (see _hook_state_tier_ok),
# and the first writable tier in the fixed order wins. The sandbox is fixed
# for a session's lifetime, so every hook of a session lands on the same
# tier and counters never split; an unsandboxed session keeps the runtime
# tier exactly as before, so a stale same-key dir in a later tier (pid keys
# repeat after reboot) is never adopted. The tmp fallback is the last resort
# and is never probed.
#
# Cost: probes are builtin redirections. The one exception is a missing,
# denied runtime root (a sandboxed agent after reboot, before any
# unsandboxed hook has created it), which pays a failing mkdir per hook.
#
# Sets _HOOK_STATE_ROOT and _HOOK_STATE_DURABLE (1 for the XDG_STATE_HOME and
# ~/.local/state tiers, which nothing wipes at logout; never for the runtime
# tier or the unhardened tmp fallback). Cached per session key and
# environment.
_hook_resolve_state_root() {
  local key="$1" root runtime='' state_home='' cache
  # The answer depends on the env as well as the key, and refreshes can run
  # again after either changes.
  cache="$key|${XDG_RUNTIME_DIR-}|${XDG_STATE_HOME-}|${HOME-}|${TMPDIR-}"
  if [ -n "${_HOOK_STATE_ROOT:-}" ] && [ "${_HOOK_STATE_ROOT_KEY-}" = "$cache" ]; then
    return 0
  fi
  case "${XDG_RUNTIME_DIR:-}" in
    /*) runtime="$XDG_RUNTIME_DIR/agentguard/hook-state" ;;
  esac
  case "${XDG_STATE_HOME:-}" in
    /*) state_home="$XDG_STATE_HOME/agentguard/hook-state" ;;
  esac
  _HOOK_STATE_ROOT_KEY="$cache"
  _HOOK_STATE_DURABLE=''
  for root in "$runtime" "$state_home" "${HOME:+$HOME/.local/state/agentguard/hook-state}"; do
    [ -n "$root" ] || continue
    _hook_state_tier_ok "$root" "$key" || continue
    _HOOK_STATE_ROOT="$root"
    [ "$root" = "$runtime" ] || _HOOK_STATE_DURABLE=1
    return 0
  done
  _HOOK_STATE_ROOT="${TMPDIR:-/tmp}/agentguard-hook-state-$(id -u 2>/dev/null || echo 0)"
}

# Whether this process can write hook state under ROOT for KEY. Probes the
# nearest existing level with a zero-byte append: a builtin redirection, so
# no fork on the hot path, and it never changes file contents. Only a missing
# root is created, privately, as the first writer would create it anyway.
_hook_state_tier_ok() {
  local root="$1" key="$2" dir="$1/$2"
  if [ -d "$dir" ]; then
    { : >>"$dir/.writable"; } 2>/dev/null
  elif [ -d "$root" ]; then
    { : >>"$root/.writable"; } 2>/dev/null
  else
    _hook_mkstate "$root" && { : >>"$root/.writable"; } 2>/dev/null
  fi
}

# Durable-tier session state outlives logout, so session start removes
# session dirs with nothing written for AGENTGUARD_STATE_PRUNE_DAYS (default
# 30). There is deliberately no SessionEnd removal: Claude --resume, Codex
# resume, and Grok reuse the session key and expect their markers (the Hive
# Memory context marker, churn counters, the bypass) to survive. A session
# idle past the window loses them, as a runtime-tier session does at logout.
# Counter rewrites do not bump a session dir's mtime, so a dir is stale only
# when nothing inside it is recent either. A live session that writes
# nothing for the whole window is pruned too; it starts over, as a
# runtime-tier session does after logout. Runs once per session start, never
# on the per-tool hot path, and never under the tmp fallback, where the tree
# may be another user's.
_hook_state_prune() {
  local days="${AGENTGUARD_STATE_PRUNE_DAYS:-30}" dir
  [ -n "${_HOOK_STATE_DURABLE:-}" ] || return 0
  [ -d "${_HOOK_STATE_ROOT:-}" ] || return 0
  # 0 (or anything non-numeric) disables pruning: `-mtime -0` matches nothing,
  # so every day-old dir would look stale however recently it was written.
  case "$days" in '' | *[!0-9]* | 0 | 0*) return 0 ;; esac
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    [ "$dir" != "${_HOOK_STATE_DIR:-}" ] || continue
    [ -z "$(find "$dir" -mtime -"$days" -print 2>/dev/null | head -n 1)" ] || continue
    rm -rf -- "$dir" 2>/dev/null || true
  done < <(find "$_HOOK_STATE_ROOT" -mindepth 1 -maxdepth 1 -type d \
    -mtime +"$days" -print 2>/dev/null)
}

# Create a hook state directory (and parents) privately. XDG_RUNTIME_DIR is
# already 0700, but the XDG_STATE_HOME/~/.local/state fallbacks inherit the
# caller's umask (typically 0755), which would let another user on a shared host
# read a session's activity metadata (which MCP servers failed, per-file edit
# churn). Creating under `umask 077` keeps every tier's state dirs 0700 to match
# the privacy the runtime tier gives for free. The subshell contains the umask.
_hook_mkstate() {
  (umask 077 && mkdir -p "$1") 2>/dev/null
}

# Whether a session key is safe to use as a single state-dir path component.
# Keys arrive from untrusted input (hook JSON, runtime env), and every state
# path is built as <root>/<key> for mkdir, write, and rm. Reject anything that
# could escape that component (`/`, `..`, `.`) or split the newline-delimited
# key streams (`\n`). Callers skip or fall back on rejection; this predicate is
# the structural layer every resolver and consumer also re-checks.
_hook_session_key_safe() {
  case "${1:-}" in
    '' | . | */* | *..*) return 1 ;;
  esac
  case "${1:-}" in
    *"
"*) return 1 ;;
  esac
  return 0
}

# Nearest long-lived agent ancestor formatted as a hook session key. This is
# the single shared pid-fallback resolver: the state-dir fallbacks below and
# the agent-shell session enumerator must produce identical keys, or a
# tool-shell command and its hooks resolve different state dirs. Defined up
# here because the source-time state refresh calls it. Muse has no stable
# runtime id, so its key is the bare agent pid; Codex/Grok/Gemini namespace
# theirs. Some Muse installs run a versioned binary (muse-bin-<version>)
# whose comm truncates to 15 characters, so the bare muse-bin- prefix
# matches every version. Match on the executable name only, never argv
# (see detect.sh for why argv lies). No `claude` branch: hooks never
# synthesize a claude-* key
# (Claude sessions always carry a session id), so emitting one would plant
# state no hook reads.
_hook_agent_ancestor_key() {
  [ "${AGENTGUARD_PROCESS_DETECT:-1}" != "0" ] || return 1
  # Share the one per-process snapshot from detect.sh: this resolver runs on
  # every state refresh, and a second `ps` would re-read the same table.
  _agent_process_snapshot || return 1
  local snapshot="$_AGENT_PROCESS_SNAPSHOT"
  [ -n "$snapshot" ] || return 1
  printf '%s\n' "$snapshot" | awk -v start="$$" '
    {
      pid = $1
      parent[pid] = $2
      $1 = $2 = ""
      sub(/^[[:space:]]+/, "")
      command[pid] = $0
    }
    END {
      if (!(start in command)) exit 1
      pid = start
      while (pid != "" && pid != "0" && !seen[pid]++) {
        name = command[pid]
        sub(/^.*\//, "", name)
        if (name == "muse.real" || name == "muse" || name ~ /^muse-bin-/) { print pid; exit 0 }
        if (name == "codex") { print "codex-" pid; exit 0 }
        if (name == "grok") { print "grok-" pid; exit 0 }
        if (name == "gemini") { print "gemini-" pid; exit 0 }
        if (!(pid in parent)) exit 1
        next_pid = parent[pid]
        if (next_pid == pid) exit 1
        pid = next_pid
      }
      exit 1
    }
  '
}

# Session key for state directory isolation. Prefer stable runtime ids. Codex
# hook commands can inherit CODEX_THREAD_ID from an outer Codex process when a
# user launches nested Codex, so once Codex JSON has been read its session_id is
# the authoritative key. If Codex does not expose one, managed hooks fall back
# to the long-lived Codex parent process instead of each short-lived hook
# process. Grok injects GROK_SESSION_ID on hook processes. Gemini exports its
# durable GEMINI_SESSION_ID to hook processes only, which tool shells cannot
# rely on, so guard state keys on the parent CLI process both sides can
# resolve (durable telemetry records use the session id; see
# _hook_telemetry_key). Other hook runners
# may only provide a JSON session_id / sessionId on stdin; parsers refresh
# after reading it. Empty or session-less JSON must still fall through to the
# Codex process key; otherwise reading a closed stdin would downgrade an
# already-stable session to this one hook process.
#
# Grok SessionStart does not fire for subagent sessions, so children inherit
# the parent GROK_SESSION_ID (and AGENTGUARD_SESSION_ID copied from it) or fall
# back to grok-$PPID. Child events carry camelCase subagentType; when that is
# present, prefer a distinct JSON sessionId as Grok's child session, otherwise
# suffix the parent key with subagentType so overlapping children do not share
# circuit-breaker or Hive Memory markers with the parent. Parent SessionStart
# and Stop omit subagentType and keep the unsuffixed key.
_hook_refresh_state_dir() {
  local session_key='' input_session='' input_subagent='' input_prompt='' input_event='' codex_key='' ancestor=''
  if [ -n "${_HOOK_INPUT+x}" ]; then
    # Grok's hook envelope is camelCase (sessionId, subagentType); Claude/Codex
    # remain snake_case. Prefer snake_case so an existing runtime stays
    # authoritative if a payload ever contains both. One jq keeps the large
    # PostToolUse payload under the cached-parse jq budget.
    {
      IFS= read -r input_session || true
      IFS= read -r input_subagent || true
      IFS= read -r input_prompt || true
      IFS= read -r input_event || true
    } < <(printf '%s' "$_HOOK_INPUT" | jq -r '
      # One output line per field: strings (and numbers, as before) count, an
      # object or array would print as multi-line JSON so it does not, and
      # CR/LF are removed so a value can never shift the fields after it.
      # split/join rather than gsub: jq 1.6 regex costs ~1 ms on this hot path.
      def line:
        if type == "string" then split("\n") | join("") | split("\r") | join("")
        elif type == "number" then tostring
        else "" end;
      ((.session_id // .sessionId) | line),
      ((.subagent_type // .subagentType) | line),
      ((.prompt_id // .promptId) | line),
      ((.hook_event_name // .hookEventName) | line)
    ' 2>/dev/null)
  fi

  # Precedence note: these launcher ids are mutually exclusive in practice
  # (each launcher exports only its own), so their relative order only
  # matters for synthetic co-occurrence. MUSE ranks below GROK here while
  # `_hook_agent_shell_session_keys` ranks it second; both orders agree
  # whenever at most one launcher id is set, which is the only real case.
  if [ "${AGENTGUARD_NAME:-}" = "codex" ] && [ -n "$input_session" ]; then
    session_key="$input_session"
  elif [ -n "${AGENTGUARD_SESSION_ID:-}" ]; then
    session_key="$AGENTGUARD_SESSION_ID"
  elif [ -n "${CODEX_THREAD_ID:-}" ]; then
    session_key="$CODEX_THREAD_ID"
  elif [ -n "${GROK_SESSION_ID:-}" ]; then
    session_key="$GROK_SESSION_ID"
  elif [ -n "${MUSE_SESSION_ID:-}" ]; then
    session_key="$MUSE_SESSION_ID"
  elif [ "${AGENTGUARD_NAME:-}" != "codex" ] && [ -n "${CLAUDE_CODE_CURRENT_SESSION_ID:-}" ]; then
    session_key="$CLAUDE_CODE_CURRENT_SESSION_ID"
  elif [ "${AGENTGUARD_NAME:-}" != "codex" ] && [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
    session_key="$CLAUDE_CODE_SESSION_ID"
  elif [ -n "$input_session" ]; then
    session_key="$input_session"
  fi

  # Prime the shared process snapshot in this shell before the subshell
  # resolutions below. They cannot persist the cache themselves ($() state
  # dies with the subshell), but they inherit it — so one fetch here serves
  # the codex key, the ancestor key, and every later _agent_name probe in
  # this hook process. The condition matches exactly the processes that will
  # probe: an empty key means no id vars, and disabled detection probes
  # nothing anywhere downstream except the explicit codex-name path
  # (`_hook_codex_process_key` still probes under AGENTGUARD_NAME=codex).
  if [ -z "$session_key" ] && [ "${AGENTGUARD_PROCESS_DETECT:-1}" != "0" ]; then
    _agent_process_snapshot || true
  fi

  if [ -z "$session_key" ] && codex_key=$(_hook_codex_process_key); then
    session_key="$codex_key"
  elif [ -z "$session_key" ] && [ "${AGENTGUARD_NAME:-}" = "grok" ]; then
    # Nearest grok ancestor, so hooks spawned through a wrapper resolve the
    # same key as a tool shell in the same session (which cannot see this
    # hook's $PPID). A foreign-runtime ancestor belongs to another session's
    # state, so only a grok-shaped key is accepted here.
    ancestor=$(_hook_agent_ancestor_key 2>/dev/null) || ancestor=''
    case "$ancestor" in
      grok-*) session_key="$ancestor" ;;
      *) session_key="grok-$PPID" ;;
    esac
  elif [ -z "$session_key" ] && [ -n "${GEMINI_PROJECT_DIR:-}" ]; then
    ancestor=$(_hook_agent_ancestor_key 2>/dev/null) || ancestor=''
    case "$ancestor" in
      gemini-*) session_key="$ancestor" ;;
      *) session_key="gemini-$PPID" ;;
    esac
  fi

  if [ -z "$session_key" ]; then
    # No runtime id anywhere (notably id-less Muse): the stable key is the
    # agent ancestor pid, matching what a tool shell resolves. Only a bare
    # pid is accepted: a namespaced key belongs to another runtime's session.
    # Unreachable processes and disabled detection keep the historical `$$`.
    ancestor=$(_hook_agent_ancestor_key 2>/dev/null) || ancestor=''
    case "$ancestor" in
      '' | *-* | *[!0-9]*) session_key="$$" ;;
      *) session_key="$ancestor" ;;
    esac
  fi

  if [ -n "$input_subagent" ]; then
    if [ "${AGENTGUARD_NAME:-}" = "grok" ] ||
      { [ -z "${AGENTGUARD_NAME:-}" ] && [ -n "${GROK_SESSION_ID:-}" ]; }; then
      if [ -n "$input_session" ] &&
        [ "$input_session" != "$session_key" ] &&
        [ "$input_session" != "${GROK_SESSION_ID:-}" ] &&
        [ "$input_session" != "${AGENTGUARD_SESSION_ID:-}" ]; then
        session_key="$input_session"
      else
        # Two concurrent children of the same type share GROK_SESSION_ID
        # and subagentType. promptId is the remaining stable discriminator
        # when Grok does not mint a distinct child sessionId.
        session_key="$session_key:$input_subagent"
        [ -n "$input_prompt" ] && session_key="$session_key:$input_prompt"
      fi
    fi
  fi

  # Env and JSON ids are untrusted input for a path component: a key
  # containing `/` or `..` would escape the state tree for mkdir, counter
  # writes, and marker removal alike, so an unsafe key falls back to this
  # hook process instead of being trusted structurally anywhere downstream.
  _hook_session_key_safe "$session_key" || session_key="$$"

  # Kept for telemetry, which keys durable records by the payload's own id
  # where the state key is process-scoped (see _hook_telemetry_key).
  _HOOK_INPUT_SESSION="$input_session"
  _HOOK_INPUT_EVENT="$input_event"
  _HOOK_SESSION_KEY="$session_key"
  _hook_resolve_state_root "$_HOOK_SESSION_KEY"
  _HOOK_STATE_DIR="$_HOOK_STATE_ROOT/$_HOOK_SESSION_KEY"
  if [ -n "${_HOOK_INPUT+x}" ]; then
    _HOOK_INPUT_STATE_REFRESHED=1
  else
    _HOOK_INPUT_STATE_REFRESHED=''
  fi
}

# String prefilter: does this payload mention any field the state refresh
# reads (`session_id`/`sessionId`, `subagent_type`/`subagentType`,
# `prompt_id`/`promptId`), or a failure event whose name post hooks must echo
# (`_HOOK_INPUT_EVENT`)? A payload mentioning none of them re-resolves the
# exact key the source-time refresh already computed. False positives (a
# command containing the word "session") just take the slow path. Any
# `\uXXXX` escape also takes the slow path, so JSON-escaped key spellings
# (e.g. `ses\u0073ion_id`) cannot false-negative.
_hook_input_has_session_fields() {
  case "${1:-}" in
    *session* | *subagent* | *prompt* | *PostToolUseFailure* | *\\u*) return 0 ;;
    *) return 1 ;;
  esac
}

# Post-input refresh that skips payloads without session fields. Call only
# once hook JSON is available: without session fields the key is provably the
# source-time key, so this marks the input refreshed instead of re-running
# jq plus process probing for the same answer.
_hook_refresh_state_dir_for_input() {
  if _hook_input_has_session_fields "${_HOOK_INPUT:-}"; then
    _hook_refresh_state_dir
  else
    _HOOK_INPUT_STATE_REFRESHED=1
  fi
}

_hook_refresh_state_dir
_hook_capture_stderr

# --- Accumulators (stderr-only, never touch stdout) ---

_hook_block() {
  _HOOK_BLOCKED=1
  _hook_telemetry_note _HOOK_TELEMETRY_BLOCKS "$1"
  printf 'BLOCKED: %s\n' "$1" >&2
}

_hook_warn() {
  local message="$1"
  _hook_telemetry_note _HOOK_TELEMETRY_WARNINGS "$message"
  printf 'WARNING: %s\n' "$message" >&2
  # Successful hook stderr is not a reliable model-visible channel across
  # agents. Warnings are behavioral steer, so carry them through the protocol
  # context too while preserving stderr for logs and human debugging.
  _hook_context "$message"
}

_hook_remind() {
  local message="$1"
  _hook_telemetry_note _HOOK_TELEMETRY_REMINDERS "$message"
  printf 'REMINDER: %s\n' "$message" >&2
  # Same rationale as _hook_warn: reminders should affect the next model turn,
  # not depend on whether a client happens to surface successful-hook stderr.
  _hook_context "$message"
}

_hook_prompt_cycle_reset() {
  # UserPromptSubmit is the clean boundary between requests. Short-lived hooks
  # can use this directory to avoid repeating broad guidance during one edit
  # cycle while still rearming for the next human prompt.
  rm -rf "$_HOOK_STATE_DIR/prompt-cycle" 2>/dev/null || true
}

_hook_mark_once() {
  local dir="$1" key="$2" marker
  marker="$dir/$key"
  [ ! -e "$marker" ] || return 1

  # If state cannot be written, fail open and show the reminder or warning.
  # Missing a de-duplication marker is less harmful than silently dropping
  # behavioral steer. The directory test spares the subshell and mkdir once
  # the directory exists (a Stop marks one per unwatched key).
  [ -d "$dir" ] || _hook_mkstate "$dir" || return 0
  : >"$marker" 2>/dev/null || true
  return 0
}

_hook_once_per_prompt() {
  _hook_mark_once "$_HOOK_STATE_DIR/prompt-cycle" "$1"
}

_hook_once_per_session() {
  _hook_mark_once "$_HOOK_STATE_DIR" "$1"
}

# Return whether the current host identifies this Stop as a continuation. Keep
# raw payload vocabulary behind one predicate so launchers never grow
# agent-specific branches as compatible runtimes evolve.
_hook_stop_active() {
  [ -n "${_HOOK_INPUT:-}" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  printf '%s' "$_HOOK_INPUT" |
    jq -e '.stop_hook_active == true or .stopHookActive == true' >/dev/null 2>&1
}

# Atomically claim the one audible notification in a prompt cycle. Unlike
# behavioral reminders, sound must fail silent when state cannot be persisted;
# failing open here would recreate the repeated-bell failure under concurrency
# or a temporarily unavailable state root.
_hook_stop_claim_notification() {
  local dir="$_HOOK_STATE_DIR/prompt-cycle"
  _hook_mkstate "$dir" || return 1
  mkdir "$dir/stop-notified" 2>/dev/null
}

# Return whether this Stop ends the user's foreground turn. SubagentStop does
# not: Grok still delivers it through agent-hook-stop because that launcher is
# the empty-JSON gate.
_hook_stop_is_foreground() {
  local child_type='' event_name=''
  if [ -z "$_HOOK_STOP_FOREGROUND" ]; then
    _HOOK_STOP_FOREGROUND=1
    _hook_hm_read_input
    if [ -n "${_HOOK_INPUT+x}" ]; then
      child_type=$(printf '%s' "$_HOOK_INPUT" | jq -r '.subagent_type // .subagentType // empty' 2>/dev/null) || child_type=''
      if [ -n "$child_type" ]; then
        _HOOK_STOP_FOREGROUND=0
      else
        event_name=$(printf '%s' "$_HOOK_INPUT" | jq -r '.hookEventName // .hook_event_name // empty' 2>/dev/null) || event_name=''
        case "$event_name" in
          SubagentStop | subagent_stop | SubagentEnd | subagent_end) _HOOK_STOP_FOREGROUND=0 ;;
        esac
      fi
    fi
  fi
  [ "$_HOOK_STOP_FOREGROUND" = 1 ]
}

# Return success once per foreground prompt cycle so a completed response can
# notify without repeated Stop callbacks ringing for background continuations.
# AgentGuard state is canonical across runtimes; stop_hook_active is only an
# additional recursion guard when a host exposes that compatible field. It
# cannot guard a continuation AgentGuard's own Stop caused: that Stop stayed
# silent, so the flagged Stop that follows may be the turn's real end. Call
# this only for a Stop that does not continue (see _hook_stop_continues).
_hook_stop_should_notify() {
  _hook_stop_is_foreground || return 1
  if _hook_stop_active && ! _hook_stop_was_continued; then
    return 1
  fi
  _hook_stop_claim_notification
}

# Record that this foreground Stop's response kept the turn going, so a later
# Stop in the same prompt cycle can still ring although the host flags it as a
# continuation. A failed write only costs that bell; it never adds one.
_hook_stop_mark_continued() {
  local dir="$_HOOK_STATE_DIR/prompt-cycle"
  _hook_mkstate "$dir" || return 0
  : >"$dir/stop-continued" 2>/dev/null || true
}

_hook_stop_was_continued() {
  [ -e "$_HOOK_STATE_DIR/prompt-cycle/stop-continued" ]
}

# Arm the Stop hook so it settles the turn on every exit, not just through the
# launcher's own decision: an extension can crash, call exit, or be signalled
# by a host timeout, and the old pre-extension bell covered those paths.
# Deliberately no HUP/TERM traps: once an EXIT trap exists, non-interactive
# Bash (3.2 included) runs it on those signals at once, even mid-command,
# while a trap of our own would wait for the running command to return.
# SIGKILL cannot be caught at all.
_hook_stop_arm() {
  _HOOK_STOP_PENDING=1
}

# Ring and clear the busy mark when this foreground Stop ends the turn, or mark
# it continued so its flagged follow-up can still ring. $1 is 1 when the Stop's
# response keeps the agent working. Pending clears last, so a signal midway
# lets _hook_exit finish the job; the bell claim and the idempotent clear make
# a repeat harmless.
_hook_stop_settle() {
  if _hook_stop_is_foreground; then
    if [ "$1" = 1 ]; then
      _hook_stop_mark_continued
    else
      if _hook_stop_should_notify; then
        # --owner: an agent this one launched cannot mark this agent's pane pending.
        term-notify-sound --owner "$PPID" >/dev/null 2>&1 || true
      fi
      _hook_pane_busy clear
    fi
  fi
  _HOOK_STOP_PENDING=''
}

# Settle a Stop that exits before the launcher decided. Only a block that
# _hook_finish emitted continues the turn; the exit status cannot tell: after
# a signal, the EXIT trap sees the last command's status while the host sees
# the signal. Anything else (a crash, a raw exit, a signal) ends the turn; an
# extension that exits 2 itself instead of calling _hook_block therefore gets
# the bell and busy clear although the host continues.
_hook_stop_settle_exit() {
  # An empty first read already waited on stdin; a payload-less Stop is
  # foreground, so do not wait again (as telemetry avoids).
  if [ -z "${_HOOK_INPUT+x}" ] && [ -n "$_HOOK_INPUT_ATTEMPTED" ]; then
    _HOOK_STOP_FOREGROUND=1
  fi
  if [ -n "$_HOOK_EMITTED" ] && _hook_stop_continues; then
    _hook_stop_settle 1
  else
    _hook_stop_settle 0
  fi
}

# Return whether this Stop hook's response keeps the agent working. A block
# exits 2, which continues the turn, except on Codex, where _hook_finish keeps
# Stop fail-open, and on hosts whose adapter sets AGENTGUARD_STOP_BLOCK_ENDS_TURN
# because they log a Stop's exit 2 and end the turn anyway (OpenCode, under
# whatever runtime name it is configured with). A host that ignores exit 2
# without declaring it loses the bell when an extension blocks.
_hook_stop_continues() {
  [ -n "$_HOOK_BLOCKED" ] || return 1
  _hook_flag_enabled "${AGENTGUARD_STOP_BLOCK_ENDS_TURN:-}" && return 1
  local _stop_agent_name
  _hook_agent_name _stop_agent_name
  [ "$_stop_agent_name" != codex ]
}

# Return whether this event ends the foreground turn without a Stop callback:
# a failed request (StopFailure) or a user interrupt (Interrupt). A subagent's
# event (OpenCode reports one under the root session with agent_id) ends only
# the child, and OpenCode's "superseded" Interrupt arrives after the steering
# prompt that replaced the turn, so neither ends it. The telemetry hook runs on
# every tool call, so a substring prefilter skips jq for ordinary payloads.
_hook_turn_aborted() {
  case "${_HOOK_INPUT:-}" in
    *StopFailure* | *Interrupt*) ;;
    *) return 1 ;;
  esac
  command -v jq >/dev/null 2>&1 || return 1
  printf '%s' "$_HOOK_INPUT" | jq -e '
    ((.hook_event_name // .hookEventName) | . == "StopFailure" or . == "Interrupt")
    and (.agent_id // .agentId) == null
    and .reason != "superseded"
  ' >/dev/null 2>&1
}

# Return whether this hook's session is foreground work whose turns the busy
# mark tracks. Codex runs background agents (memory consolidation, task-title
# generation) as ephemeral sessions inside the user's Codex process: the same
# process and pane, their own prompts, Stops, and Interrupts, and no
# transcript. They must neither mark an idle pane nor clear the user's turn.
# The cost is that `codex exec --ephemeral` run directly in a pane, also
# transcript-less, is not marked either.
_hook_busy_tracked() {
  local _busy_agent_name
  _hook_agent_name _busy_agent_name
  [ "$_busy_agent_name" = codex ] || return 0
  _hook_hm_read_input
  [ -n "${_HOOK_INPUT:-}" ] || return 0
  ! printf '%s' "$_HOOK_INPUT" |
    jq -e 'has("transcript_path") and .transcript_path == null' >/dev/null 2>&1
}

# Set or clear the busy mark on the agent's tmux pane, so the terminal can show
# which agents are working. cmdblocks' term-pane-mark owns the mark and finds
# the hook's pane even when an agent strips the tmux variables. --owner names
# the agent process that runs this hook, and term-pane-mark changes the mark
# only while that process is the pane terminal's foreground program: an agent
# the outer one launches (a reviewer, Hive Memory's classifier) inherits the
# pane but not its terminal, so it cannot set or clear the outer agent's mark.
# Optional and best effort: without the command, or outside tmux, nothing is
# marked.
_hook_pane_busy() {
  command -v term-pane-mark >/dev/null 2>&1 || return 0
  _hook_busy_tracked || return 0
  term-pane-mark "$1" busy --owner "$PPID" >/dev/null 2>&1 || true
}

_hook_flag_enabled() {
  case "${1:-}" in
    1 | true | TRUE | yes | YES | on | ON) return 0 ;;
    *) return 1 ;;
  esac
}

# The false spellings for a default-on knob. An unset or unrecognized value is
# not "disabled", so the default holds.
_hook_flag_disabled() {
  case "${1:-}" in
    0 | false | FALSE | no | NO | off | OFF) return 0 ;;
    *) return 1 ;;
  esac
}

_hook_edit_churn_file() {
  local path="$1" key
  key=$(printf '%s' "$path" | cksum | cut -d' ' -f1)
  printf '%s/edit-churn/%s\n' "$_HOOK_STATE_DIR" "$key"
}

_hook_counter_read() {
  local file="$1" count=''
  if [ -f "$file" ]; then
    IFS= read -r count <"$file" 2>/dev/null || count=''
  fi
  case "$count" in
    '' | *[!0-9]*) count=0 ;;
  esac
  printf '%s\n' "$count"
}

_hook_counter_increment() {
  local file="$1" dir count
  dir="${file%/*}"
  if [ "$dir" != "$file" ]; then
    _hook_mkstate "$dir" || return 0
  fi
  count=$(_hook_counter_read "$file")
  printf '%s\n' "$((count + 1))" >"$file" 2>/dev/null || true
}

_hook_counter_reset() {
  rm -f "$1" 2>/dev/null || true
}

# --- Edit-churn bypass: hook predicate plus agent-shell resolver ---
#
# The churn guard counts per-file edits in the session state dir. The bypass
# used to live only in $AGENTGUARD_EDIT_CHURN_BYPASS, which a hook reads from
# its own environment — inherited from the agent process at spawn time. An
# `export` in an agent tool shell cannot reach that environment (a Unix child
# cannot change its parent's env), so a mid-session bypass needs a channel
# the agent itself can write: a marker file in the session state dir. The
# marker is session-scoped (one primary key per shell, cleared at every
# SessionStart so a reused key never inherits it) and opt-in (absent by
# default), so the guard's default behavior is unchanged.

_hook_edit_churn_bypass_file() {
  printf '%s/edit-churn-bypass\n' "$_HOOK_STATE_DIR"
}

_hook_edit_churn_bypassed() {
  _hook_flag_enabled "${AGENTGUARD_EDIT_CHURN_BYPASS:-}" && return 0
  [ -f "$(_hook_edit_churn_bypass_file)" ]
}

# Remove this session's bypass marker from every root tier. Called from
# SessionStart (wired for every runtime, including Grok subagents via
# SubagentStart) so a new session always starts un-bypassed even when its key
# is reused: pid-derived keys repeat after logout/reboot while markers persist
# in the state-home tiers. This is the stale-marker mitigation; the predicate
# above stays a cheap file test. Mid-session `on` is unaffected: the CLI runs
# in a tool shell, which only exists after the session (and its SessionStart)
# has fired.
_hook_edit_churn_bypass_clear() {
  local root
  [ -n "${_HOOK_SESSION_KEY:-}" ] || return 0
  _hook_session_key_safe "${_HOOK_SESSION_KEY:-}" || return 0
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    rm -f "$root/$_HOOK_SESSION_KEY/edit-churn-bypass" 2>/dev/null || true
  done < <(_hook_state_roots)
}

# Every plausible per-user hook state root, most-preferred first. Hook
# processes often run with XDG_* scrubbed from their environment, so an
# agent-shell helper must probe each root instead of trusting its own env
# (mirrors the _hook_resolve_state_root tiers without picking one).
_hook_state_roots() {
  local root seen=' '
  for root in \
    "${XDG_RUNTIME_DIR:+$XDG_RUNTIME_DIR/agentguard/hook-state}" \
    "${XDG_STATE_HOME:+$XDG_STATE_HOME/agentguard/hook-state}" \
    "${HOME:+$HOME/.local/state/agentguard/hook-state}" \
    "${TMPDIR:-/tmp}/agentguard-hook-state-$(id -u 2>/dev/null || echo 0)"; do
    [ -n "$root" ] || continue
    case "$root" in /*) ;; *) continue ;; esac
    case "$seen" in *" $root "*) continue ;; esac
    seen="$seen$root "
    printf '%s\n' "$root"
  done
}

# Candidate hook session keys visible from an agent tool shell, best first:
# explicit runtime ids (same precedence as _hook_refresh_state_dir, plus
# MUSE_SESSION_ID, which launchers map to AGENTGUARD_SESSION_ID only in hook
# env), then the agent-ancestor fallback. Unsafe ids are skipped here, so
# every downstream consumer is safe by construction; consumers re-check
# anyway (defense in depth).
_hook_agent_shell_session_keys() {
  local key ancestor seen=' '
  for key in \
    "${AGENTGUARD_SESSION_ID:-}" \
    "${MUSE_SESSION_ID:-}" \
    "${CODEX_THREAD_ID:-}" \
    "${GROK_SESSION_ID:-}" \
    "${CLAUDE_CODE_CURRENT_SESSION_ID:-}" \
    "${CLAUDE_CODE_SESSION_ID:-}"; do
    [ -n "$key" ] || continue
    _hook_session_key_safe "$key" || continue
    case "$seen" in *" $key "*) continue ;; esac
    seen="$seen$key "
    printf '%s\n' "$key"
  done
  ancestor=$(_hook_agent_ancestor_key 2>/dev/null) || ancestor=''
  if [ -n "$ancestor" ]; then
    _hook_session_key_safe "$ancestor" || return 0
    case "$seen" in *" $ancestor "*) ;; *) printf '%s\n' "$ancestor" ;; esac
  fi
}

# The ONE session this tool shell manages: the first candidate key with an
# existing state dir in any root tier, else the first candidate key (for
# marker creation before any hook has run). Single-key scoping keeps a nested
# agent's bypass from disabling the outer session's guard; callers must never
# fan out across keys. Tiers still fan out across roots: hooks deterministically
# use one root tier, but a tool shell cannot know which (hook env often has
# XDG_* scrubbed while the shell does not).
_hook_agent_shell_primary_key() {
  local key root
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    while IFS= read -r root; do
      [ -n "$root" ] || continue
      if [ -d "$root/$key" ]; then
        printf '%s\n' "$key"
        return 0
      fi
    done < <(_hook_state_roots)
  done < <(_hook_agent_shell_session_keys)
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    printf '%s\n' "$key"
    return 0
  done < <(_hook_agent_shell_session_keys)
  return 1
}

# Every existing <root>/<key> session dir for this tool shell's primary
# session key, across plausible roots. Single key, many tiers: the key picks
# the session, the tiers cover the root the hooks actually read.
_hook_agent_shell_state_dirs() {
  local key root candidate found=0
  key=$(_hook_agent_shell_primary_key 2>/dev/null) || return 1
  _hook_session_key_safe "$key" || return 1
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    candidate="$root/$key"
    [ -d "$candidate" ] || continue
    printf '%s\n' "$candidate"
    found=1
  done < <(_hook_state_roots)
  [ "$found" -eq 1 ]
}

# Newest write inside a session dir: the dir itself plus its churn counters
# and bypass marker. Counter rewrites do not bump the dir mtime, so comparing
# bare dir mtimes lets a freshly created tier beat a live one.
_hook_state_dir_newest() {
  local dir="$1" entry newest=''
  for entry in "$dir" "$dir"/edit-churn/* "$dir"/edit-churn-bypass; do
    [ -e "$entry" ] || continue
    if [ -z "$newest" ] || [ "$entry" -nt "$newest" ]; then
      newest="$entry"
    fi
  done
  printf '%s\n' "$newest"
}

# Resolve this tool shell's primary hook session dir: the primary key's
# existing tier with the most recent write inside. Newest-contents wins so a
# live tier beats a stale same-key dir left behind in another root tier. The
# key is fixed (never newest-across-keys) so a nested session cannot steal
# the outer session's summary — or its bypass.
_hook_agent_shell_state_dir() {
  local key root candidate best='' best_new='' new
  key=$(_hook_agent_shell_primary_key 2>/dev/null) || return 1
  _hook_session_key_safe "$key" || return 1
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    candidate="$root/$key"
    [ -d "$candidate" ] || continue
    new=$(_hook_state_dir_newest "$candidate")
    if [ -z "$best" ]; then
      best="$candidate"
      best_new="$new"
    elif [ -n "$new" ] && { [ -z "$best_new" ] || [ "$new" -nt "$best_new" ]; }; then
      best="$candidate"
      best_new="$new"
    fi
  done < <(_hook_state_roots)
  [ -n "$best" ] || return 1
  printf '%s\n' "$best"
}

_hook_require_sley() {
  if ! command -v sley >/dev/null 2>&1; then
    _hook_block "sley command missing; install cgraf78/sley with shdeps"
    return 2
  fi
}

# Accumulates context lines for hooks that emit JSON (SessionStart,
# UserPromptSubmit). Avoids leading newline when first line is added.
_hook_context() {
  if [ -n "$_HOOK_CTX" ]; then
    _HOOK_CTX="${_HOOK_CTX}
$1"
  else
    _HOOK_CTX="$1"
  fi
}

# --- Input parsing ---

_hook_read_input() {
  if [ -n "${_HOOK_INPUT+x}" ]; then
    [ "$_HOOK_INPUT_STATE_REFRESHED" = 1 ] || _hook_refresh_state_dir_for_input
    return 0
  fi
  [ ! -t 0 ] || return 1
  _HOOK_INPUT_ATTEMPTED=1
  local input stdin_timeout stdin_drain_timeout stdin_total_timeout stdin_drain_timeout_int
  local chunk read_rc drain_deadline
  stdin_timeout="${AGENTGUARD_HOOK_STDIN_TIMEOUT:-0.05}"
  stdin_drain_timeout="${AGENTGUARD_HOOK_STDIN_DRAIN_TIMEOUT:-1}"
  stdin_total_timeout="${AGENTGUARD_HOOK_STDIN_TOTAL_TIMEOUT:-30}"
  case "$stdin_total_timeout" in
    # More than 15 digits would overflow the $((10#...)) conversion below.
    '' | *[!0-9]* | ????????????????*) stdin_total_timeout=30 ;;
  esac
  # Force base 10: without it, a value like 08 would be read as octal by
  # $((...)) below and kill the hook with an arithmetic error.
  stdin_total_timeout=$((10#$stdin_total_timeout))
  # Bash 3.2 (still /bin/bash on macOS) rejects fractional `read -t`
  # timeouts, so the bash-3-reachable branches below drain with an
  # integer-coerced timeout; bash 4+ and the perl branch keep fractions.
  stdin_drain_timeout_int="$stdin_drain_timeout"
  if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
    case "$stdin_drain_timeout_int" in
      '' | *[!0-9]*) stdin_drain_timeout_int=1 ;;
    esac
    stdin_drain_timeout_int=$((10#$stdin_drain_timeout_int))
  fi
  # Some hook runners attach a non-tty stdin pipe before they have any payload
  # to send. A plain `cat` waits for EOF and can consume the runner's whole hook
  # timeout, so read at most the bytes that arrive promptly.
  #
  # Once the first byte arrives the producer is live, but on a loaded host it
  # can be descheduled mid-payload for longer than one drain window (sixteen
  # parallel 300 KB hook payloads did exactly this on macOS CI: one record
  # landed truncated and its printf died with a broken pipe). An idle drain
  # window is therefore not EOF: keep draining while bytes arrive, and stop
  # on a real EOF or when the total bound below expires, so a producer
  # stalled by the scheduler loses nothing and a dead one still cannot
  # hang the hook. (A stall outlasting the total bound still truncates:
  # the wait is bounded, not infinite.)
  if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ] && [[ "$stdin_timeout" == *.* ]] &&
    command -v perl >/dev/null 2>&1; then
    input=$(
      perl -e '
        use strict;
        use warnings;
        use IO::Select;

        my $timeout = shift @ARGV;
        my $drain_timeout = shift @ARGV;
        my $total_timeout = shift @ARGV;
        $total_timeout = 30 unless defined($total_timeout) && $total_timeout =~ /^\d+$/;
        my $select = IO::Select->new(*STDIN);
        my $input = "";
        if ($select->can_read($timeout)) {
          # The short timeout guards pipes with no payload. Once data starts,
          # an idle drain window is not EOF: the producer may be descheduled
          # on a loaded host, so keep waiting up to a bounded total instead
          # of truncating the payload at the first quiet window.
          my $deadline = time + $total_timeout;
          while (1) {
            if ($select->can_read($drain_timeout)) {
              my $chunk = "";
              my $read = sysread(STDIN, $chunk, 65536);
              last if !defined($read) || $read == 0;
              $input .= $chunk;
              last if time >= $deadline;
            } elsif (time >= $deadline) {
              last;
            }
          }
        }
        print $input;
      ' "$stdin_timeout" "$stdin_drain_timeout" "$stdin_total_timeout"
    )
  elif [ "${BASH_VERSINFO[0]:-0}" -lt 4 ] && [[ "$stdin_timeout" == *.* ]]; then
    # Bash 3, still shipped as /bin/bash on macOS, rejects fractional timeouts.
    # Without Perl's `select`, fall back to an integer timeout only if bytes
    # are already ready so open-empty pipes still return promptly.
    IFS= read -r -t 0 -d '' input || return 1
    drain_deadline=$((SECONDS + stdin_total_timeout))
    while :; do
      chunk=''
      IFS= read -r -t "$stdin_drain_timeout_int" -d '' chunk
      read_rc=$?
      input+="$chunk"
      if [ "$read_rc" -eq 0 ]; then
        # Delimiter found: more may follow, inside the total bound
        # (matches the perl branch).
        [ "$SECONDS" -lt "$drain_deadline" ] || break
        continue
      elif [ "$read_rc" -eq 1 ]; then
        # EOF: the writer is gone, so nothing more is coming even if this
        # read delivered a partial final chunk. Break at once: on some
        # platforms a further read will not observe the already-consumed
        # EOF and would block until its timeout instead.
        break
      elif [ "$read_rc" -gt 128 ] && [ -n "$chunk" ]; then
        # Timeout cut a chunk short: no EOF was observed, so keep
        # draining, inside the total bound.
        [ "$SECONDS" -lt "$drain_deadline" ] || break
        continue
      elif [ "$read_rc" -gt 128 ]; then
        # Quiet window, no data: the producer may be descheduled. Wait on,
        # but only inside the total bound.
        [ "$SECONDS" -lt "$drain_deadline" ] && continue
        break
      else
        break # Other read error: nothing more is coming.
      fi
    done
  else
    # `read -t -d ''` applies one deadline to the entire payload. That can
    # truncate large command output on a loaded host even while bytes continue
    # to arrive. Keep the short first-byte timeout, then drain to EOF: a quiet
    # drain window ends the read only once the total bound below expires.
    # `-n` is supported by Bash 3.2; `-N` is not.
    IFS= read -r -t "$stdin_timeout" -d '' -n 1 input || return 1
    drain_deadline=$((SECONDS + stdin_total_timeout))
    while :; do
      chunk=''
      IFS= read -r -t "$stdin_drain_timeout_int" -d '' -n 4096 chunk
      read_rc=$?
      input+="$chunk"
      if [ "$read_rc" -eq 0 ]; then
        # Full chunk (or NUL delimiter): more may follow, inside the
        # total bound (matches the perl branch).
        [ "$SECONDS" -lt "$drain_deadline" ] || break
        continue
      elif [ "$read_rc" -eq 1 ]; then
        # EOF: the writer is gone, so nothing more is coming even if this
        # read delivered a partial final chunk. Break at once: on some
        # platforms a further read will not observe the already-consumed
        # EOF and would block until its timeout instead.
        break
      elif [ "$read_rc" -gt 128 ] && [ -n "$chunk" ]; then
        # Timeout cut a chunk short: no EOF was observed, so keep
        # draining, inside the total bound.
        [ "$SECONDS" -lt "$drain_deadline" ] || break
        continue
      elif [ "$read_rc" -gt 128 ]; then
        # Quiet window, no data: the producer may be descheduled on a loaded
        # host (the macOS CI truncation). Wait on, but only inside the total
        # bound, so a dead producer cannot hang the hook.
        [ "$SECONDS" -lt "$drain_deadline" ] && continue
        break
      else
        break # Other read error: nothing more is coming.
      fi
    done
  fi
  # Non-interactive test shells and some hook launchers can present an already
  # closed stdin. Treat that as "no hook JSON" instead of caching an empty input:
  # an empty _HOOK_INPUT would make the state refresh look for a missing
  # session_id and could downgrade a stable Codex process key to this short-lived
  # hook process.
  [ -n "$input" ] || return 1
  _HOOK_INPUT="$input"
  # Some hook runners provide the durable session id only in JSON stdin. Refresh
  # after reading that payload so per-session state is keyed by the actual
  # session instead of falling back to this one hook process id. The
  # session-field prefilter keeps id-less payloads on the source-time key.
  _hook_refresh_state_dir_for_input
}

# Export hook text for extensions' child processes only when it fits. Linux
# rejects an environment string over 128 KiB (MAX_ARG_STRLEN) with E2BIG, and
# one oversized export makes every external command this hook runs fail.
# Oversized values stay shell variables, which sourced extensions still see.
_hook_export_if_fits() {
  local name
  for name in "$@"; do
    # shellcheck disable=SC2163 # Exports the variable named by $name.
    if _hook_fits_environment "${!name}" 2>/dev/null; then
      export "$name"
    else
      export -n "$name"
    fi
  done
}

_hook_fits_environment() {
  # Byte length, not characters; 120000 leaves room for the name and `=`.
  local LC_ALL=C
  [ "${#1}" -le 120000 ]
}

# Parses the shell command from hook JSON input. Caches the full JSON in
# _HOOK_INPUT (same contract as _hook_parse_mcp) so agent-specific and local
# extensions can read additional fields. Sets AGENTGUARD_CMD_TRIMMED (full command,
# exported for local `-work` variants) and AGENTGUARD_CMD_LINE1 (first line only, for
# command-detection guards that must ignore heredoc bodies). Exits early if no
# command.
_hook_parse_command() {
  _hook_read_input || exit 0
  # A payload is present (genuinely empty stdin already returned above). If we
  # cannot parse it, a PRE-execution hook must FAIL CLOSED: the agent harness
  # parses the payload with its own (non-jq) reader and can still run
  # .tool_input.command, so a guard that treated an unreadable payload as "empty
  # command" would let the command run completely uninspected. A PostToolUse
  # hook can't prevent anything (the command already ran), so it stays a no-op
  # on parse failure rather than emitting a misleading block.
  #
  # `_hook_event_name` is derived from the hook's own filename (no jq), and for
  # this no-context hook `_hook_finish` just emits `{}` and exits 2 — so the
  # fail-closed block works even when jq is the thing that's missing.
  local _can_block=0 _event
  _hook_event_name _event
  [ "$_event" = "PreToolUse" ] && _can_block=1
  if ! command -v jq >/dev/null 2>&1; then
    if [ "$_can_block" = 1 ]; then
      _hook_block 'cannot inspect the command: jq is not on PATH. Install jq; refusing to run the tool call unguarded.'
      _hook_finish
    fi
    exit 0
  fi
  # One jq pass serves as both the validity check and the extraction: jq
  # exits nonzero on unparsable input and prints nothing for valid JSON
  # without a command field, which are exactly the two old branches below.
  # The `?` operators suppress type errors only (indexing a string, array,
  # or number as an object): the old extractor ignored those errors and
  # treated the payload as command-less, so suppressing them preserves the
  # exit-0 contract for valid-but-non-object JSON while still failing
  # closed on unparsable input. (Declare cmd first: `local` would mask the
  # substitution's exit status.)
  local cmd _line
  if ! cmd=$(printf '%s' "$_HOOK_INPUT" | jq -r '.tool_input?.command? // .tool_input?.cmd? // .toolInput?.command? // .toolInput?.cmd? // empty' 2>/dev/null); then
    if [ "$_can_block" = 1 ]; then
      _hook_block 'cannot inspect the command: the tool payload is not valid JSON. Refusing to run it unguarded.'
      _hook_finish
    fi
    exit 0
  fi
  # Valid JSON but no command field (or one that is only a NUL, which Bash
  # drops): there is nothing to run, so nothing to guard. Still answer with the
  # normal allow response; jq 1.7 decodes a lone \u0000 to an empty string.
  # _hook_finish always exits.
  [ -n "$cmd" ] || _hook_finish
  # Strip leading whitespace exactly like the historical
  # `sed 's/^[[:space:]]*//'` (every line: sed is line-oriented, so a leading
  # newline survives into TRIMMED and empties the first line below). mapfile
  # keeps this linear; peeling one line at a time off the front copied the
  # rest of the command per line. The here-string's added newline yields the
  # final element that reproduces a trailing newline in the command.
  local -a _lines=()
  local _i
  # mapfile is Bash 4+; macOS /bin/bash 3.2 runs this hook too, so fall back
  # to a read loop there (also linear, just slower on huge inputs).
  if ((BASH_VERSINFO[0] >= 4)); then
    mapfile -t _lines <<<"$cmd"
  else
    while IFS= read -r _line; do _lines+=("$_line"); done <<<"$cmd"
  fi
  AGENTGUARD_CMD_TRIMMED=''
  for ((_i = 0; _i < ${#_lines[@]}; _i++)); do
    _line="${_lines[_i]}"
    # Anchored regex, not `${_line%%[![:space:]]*}`: Bash's longest-suffix
    # match is quadratic in the line length (a 1 MiB line took 30 seconds).
    [[ "$_line" =~ ^[[:space:]]+ ]] && _line="${_line:${#BASH_REMATCH[0]}}"
    if [ "$_i" -eq 0 ]; then
      # First line only — heredoc bodies (commit messages, etc.) start on
      # line 2 and must not trigger command-detection guards. Taken here
      # because `${TRIMMED%%$'\n'*}` is quadratic in the command length.
      # shellcheck disable=SC2034 # Exported by _hook_export_if_fits below.
      AGENTGUARD_CMD_LINE1="$_line"
    else
      AGENTGUARD_CMD_TRIMMED+=$'\n'
    fi
    AGENTGUARD_CMD_TRIMMED+="${_line}"
  done
  _hook_export_if_fits AGENTGUARD_CMD_TRIMMED AGENTGUARD_CMD_LINE1
}

# Codex reports a shell call's result as one plain string in tool_response
# (stdout and stderr combined). Muse also sends a string, but one holding a
# JSON envelope whose `output` is the combined text and whose `exit_code` /
# `terminal_status` carry the result; a command still running in the
# background has `execution_state: "background_running"` (and an empty
# `output`) instead of either. A Codex command can print text shaped
# like that envelope, so unwrapping needs both the detected runtime and the
# envelope's shape; anything else is taken as the raw string.
#
# These jq fragments are the one definition of the Muse envelope. The
# adapters splice them in only when the runtime is Muse: jq parses every
# definition it is handed, and every other runtime's post-bash would pay for
# it on each call.
_HOOK_MUSE_ENVELOPE_JQ='fromjson? | objects
  | select(has("output")
      and (has("exit_code") or has("terminal_status") or has("execution_state")))'
# A Muse call that ended without an exit code fails only on a known failure
# state. Anything else gives no status (so 0): a backgrounded shell (only an
# `execution_state` of `background_running`) is still running, and a
# cancelled command may already have done its work, so consumers gated on
# status fail open for it.
_HOOK_MUSE_STATUS_JQ='if .exit_code != null then .exit_code
  elif .terminal_status == "failed" or .terminal_status == "timed_out" then 1
  else empty end'

# Extracts shell stdout from PostToolUse-style payloads. Claude Code uses
# tool_response.stdout; other hook runners have used adjacent result/output
# object names, and Codex and Muse send one combined string (see
# _HOOK_MUSE_ENVELOPE_JQ), so keep the base post-bash scanner wired through
# this adapter instead of reading a Claude-shaped field directly.
#
# The runtime lookup is cached per process, so a caller running this inside
# `$(...)` should resolve _hook_agent_name in its own shell first; otherwise
# the lookup forks again and its answer dies with the subshell.
_hook_tool_stdout() {
  _hook_read_input || return 0
  local _tool_stdout_agent _tool_stdout_unwrap=''
  _hook_agent_name _tool_stdout_agent
  [ "$_tool_stdout_agent" != muse ] ||
    _tool_stdout_unwrap="| (($_HOOK_MUSE_ENVELOPE_JQ) | .output | strings) // ."
  printf '%s' "$_HOOK_INPUT" | jq -r '
    def text_value(v):
      if (v | type) == "string" then v else empty end;
    [
      text_value(.tool_response.stdout?),
      text_value(.tool_result.stdout?),
      text_value(.toolResult.stdout?),
      text_value(.tool_output.stdout?),
      text_value(.response.stdout?),
      text_value(.result.stdout?),
      text_value(.stdout?),
      (.tool_response? | strings '"$_tool_stdout_unwrap"')
    ] | map(select(. != "")) | .[0] // empty
  ' 2>/dev/null
}

# Succeeds when the payload's tool_response is a JSON string, the combined
# stdout+stderr shape Codex and Muse send, which _hook_tool_stdout already
# returns whole. Builtin, so a caller can skip _hook_tool_stderr's subshell
# and jq. An unescaped `"tool_response"` followed by `:` can only be an object
# key: inside a JSON string its quotes would be escaped.
_hook_tool_response_is_string() {
  _hook_read_input || return 1
  # C locale: byte matching, several times faster than multibyte on large
  # payloads.
  local LC_ALL=C
  [[ "$_HOOK_INPUT" =~ \"tool_response\"[[:space:]]*:[[:space:]]*\" ]]
}

# Extracts shell stderr from PostToolUse-style payloads, mirroring
# _hook_tool_stdout's runner-neutral field lookup.
_hook_tool_stderr() {
  _hook_read_input || return 0
  printf '%s' "$_HOOK_INPUT" | jq -r '
    def text_value(v):
      if (v | type) == "string" then v else empty end;
    [
      text_value(.tool_response.stderr?),
      text_value(.tool_result.stderr?),
      text_value(.toolResult.stderr?),
      text_value(.tool_output.stderr?),
      text_value(.response.stderr?),
      text_value(.result.stderr?),
      text_value(.stderr?)
    ] | map(select(. != "")) | .[0] // empty
  ' 2>/dev/null
}

# Succeeds when the shell tool call itself runs detached from the agent turn:
# Claude Code's Bash tool sets tool_input.run_in_background, and Gemini CLI's
# shell tool sets is_background (taken from the Gemini CLI tool schema, not
# verified against a local install; a wrong field name only fails to suppress
# advice). In a post-tool payload, a Muse result envelope reports a shell it
# backgrounded as execution_state `background_running` (terminal_status is
# accepted too, should a release report it there). Runners without such
# a signal (Codex, OpenCode) background only through shell syntax, which the
# command classifier sees. A payload without any of those names cannot carry
# them, so a builtin match skips the jq fork for the common foreground call;
# callers still ask only after a guard has already matched.
_hook_tool_runs_in_background() {
  _hook_read_input || return 1
  # No local C locale: restoring an uninstalled caller locale on return
  # makes bash print a setlocale warning, and this runs only after a match.
  local _background_agent _background_muse='empty'
  case "$_HOOK_INPUT" in
    *run_in_background* | *is_background* | *background_running*) ;;
    *) return 1 ;;
  esac
  # The envelope is spliced in only for Muse, as the other adapters do.
  _hook_agent_name _background_agent
  [ "$_background_agent" != muse ] ||
    _background_muse="(.tool_response? | strings | $_HOOK_MUSE_ENVELOPE_JQ
      | .execution_state == \"background_running\" or .terminal_status == \"background_running\")"
  printf '%s' "$_HOOK_INPUT" | jq -e '
    [ ((.tool_input? // .toolInput?) | objects |
        .run_in_background == true or .is_background == true),
      '"$_background_muse"' ] | any
  ' >/dev/null 2>&1
}

# Parses edited file paths from hook JSON input. Edit/Write style tools pass a
# single file_path; Codex API apply_patch passes a patch body (in Codex hook
# payloads, as tool_input.command), so extract the file headers from that
# structured patch format.
_hook_parse_edit_files() {
  if ! _hook_read_input; then
    AGENTGUARD_EDIT_FILES=''
    AGENTGUARD_EDIT_FILE=''
    export AGENTGUARD_EDIT_FILES AGENTGUARD_EDIT_FILE
    return 0
  fi
  AGENTGUARD_EDIT_FILES=$(printf '%s' "$_HOOK_INPUT" | jq -r '
    def tool_payload:
      .tool_input // .toolInput;
    def patch_text:
      if (tool_payload | type) == "string" then tool_payload
      elif (tool_payload | type) == "object" then
        (tool_payload.patch // tool_payload.input // tool_payload.diff // tool_payload.command // empty)
      else empty end;
    def first_seen:
      reduce .[] as $item ([]; if index($item) then . else . + [$item] end);
    [
      (tool_payload.file_path? // empty),
      (tool_payload.path? // empty),
      (patch_text | strings | split("\n")[] |
        select(test("^\\*\\*\\* (Update|Add|Delete) File: |^\\*\\*\\* Move to: ")) |
        sub("^\\*\\*\\* (Update|Add|Delete) File: "; "") |
        sub("^\\*\\*\\* Move to: "; ""))
    ] | map(select(. != "")) | first_seen[]
  ' 2>/dev/null)
  # First path; `read` stays linear where `${FILES%%$'\n'*}` is quadratic in
  # the payload length.
  IFS= read -r AGENTGUARD_EDIT_FILE <<<"$AGENTGUARD_EDIT_FILES" || AGENTGUARD_EDIT_FILE=''
  _hook_export_if_fits AGENTGUARD_EDIT_FILES AGENTGUARD_EDIT_FILE
}

# Parses MCP tool info from hook JSON input. Sets _HOOK_INPUT (full JSON for
# downstream field extraction), _HOOK_MCP_SERVER, _HOOK_MCP_TOOL_NAME, and
# _HOOK_MCP_FAIL_FILE. Exits early if the tool name or server can't be
# extracted.
_hook_parse_mcp() {
  _hook_read_input || exit 0
  local tool_name remainder context_server='' context_tool=''
  # One jq for the name and Gemini's structured MCP identity, keeping the
  # hook's parse budget. NUL-delimited: a tool name may contain a newline,
  # which would shift newline-delimited fields (tool_name truncated, the
  # context fields misassigned). NULs are stripped per field first: JSON
  # allows \u0000 escapes and jq would emit the raw byte, which would shift
  # NUL-delimited fields the same way (bash cannot hold NUL in a variable
  # anyway). split/join rather than gsub, matching the input-read path:
  # jq 1.6 regex costs ~1 ms on this hot path. Each slot always emits its
  # terminator, so a non-string value dropped by `strings` leaves an empty
  # field rather than shifting the rest.
  {
    IFS= read -r -d '' tool_name || true
    IFS= read -r -d '' context_server || true
    IFS= read -r -d '' context_tool || true
  } < <(printf '%s' "$_HOOK_INPUT" | jq -j '
    def nulstrip: split("\u0000") | join("");
    ((.tool_name // .toolName // "") | tostring | nulstrip), "\u0000",
    ((.mcp_context.server_name // "" | strings) | tostring | nulstrip), "\u0000",
    ((.mcp_context.tool_name // "" | strings) | tostring | nulstrip), "\u0000"
  ' 2>/dev/null)
  [ -z "$tool_name" ] && exit 0
  if [ -n "$context_server" ] && [ -n "$context_tool" ]; then
    # Gemini CLI sends the real server and tool names alongside its
    # mcp_<server>_<tool> spelling. Prefer them: a server name may itself
    # contain `_`, which no split of the qualified name can recover.
    _HOOK_MCP_SERVER="$context_server"
    _HOOK_MCP_TOOL_NAME="$context_tool"
  elif [[ "$tool_name" == mcp_[!_]*_?* ]] && [ "$(_hook_agent_name)" = "gemini" ]; then
    # Older Gemini payloads without mcp_context: split on the first `_`, as
    # Gemini's own parseMcpToolName does. Gated on the detected runtime
    # because elsewhere that spelling is just a tool name.
    remainder="${tool_name#mcp_}"
    _HOOK_MCP_SERVER="${remainder%%_*}"
    _HOOK_MCP_TOOL_NAME="${remainder#*_}"
  else
    case "$tool_name" in
      mcp__*__*)
        remainder="${tool_name#mcp__}"
        _HOOK_MCP_SERVER="${remainder%__*}"
        _HOOK_MCP_TOOL_NAME="${remainder##*__}"
        ;;
      *__*)
        # Grok (and Cursor-compat) MCP calls arrive as qualified server__tool
        # names, not Claude's mcp__server__tool prefix. Split on the first
        # separator so a tool name that itself contains __ stays intact.
        _HOOK_MCP_SERVER="${tool_name%%__*}"
        _HOOK_MCP_TOOL_NAME="${tool_name#*__}"
        ;;
      *) exit 0 ;;
    esac
  fi
  [ -z "$_HOOK_MCP_SERVER" ] && exit 0
  [ -z "$_HOOK_MCP_TOOL_NAME" ] && exit 0

  _HOOK_MCP_TOOL="$tool_name"
  # The server name names a state file. Gemini documents it as arbitrary
  # user-controlled text, so a `/` must not reach the path.
  _HOOK_MCP_FAIL_FILE="$_HOOK_STATE_DIR/mcp-failures-${_HOOK_MCP_SERVER//\//_}"
}

# Loads the command classifier on first use. Hooks that classify only some
# commands call this after a cheap text prefilter so ordinary commands never
# pay for sourcing it.
_hook_load_command_classifier() {
  declare -F _hook_command_fragments >/dev/null && return 0
  # shellcheck source=hook-command-classifier.sh
  # shellcheck disable=SC1091 # sibling module resolved from this file's dir.
  source "$_AGENTGUARD_LIB_DIR/hook-command-classifier.sh"
}

# Load the watch-obligation engine (watch.sh) and the GitHub recognizer
# helpers (watch-github.sh) on first use. Hooks call these only after a
# builtin prefilter matched, so other calls never pay for sourcing them.
_hook_load_watch() {
  declare -F _hook_watch_record >/dev/null && return 0
  # shellcheck source=watch.sh
  # shellcheck disable=SC1091 # sibling module resolved from this file's dir.
  source "$_AGENTGUARD_LIB_DIR/watch.sh"
}

_hook_load_watch_github() {
  _hook_load_watch && _hook_load_gh_helpers
}

# The GitHub helpers alone: post-bash's watch pass loads the engine itself
# only once a command really pushed or opened a pull request, so a
# prefilter match that turns out to be `gh pr view` parses less.
_hook_load_gh_helpers() {
  declare -F _hook_gh_pr_key_scope >/dev/null && return 0
  # shellcheck source=watch-github.sh
  # shellcheck disable=SC1091 # sibling module resolved from this file's dir.
  source "$_AGENTGUARD_LIB_DIR/watch-github.sh"
}

# Pull-request checks prefilters, shared by post-bash and the watch pass in
# watch-github.sh (_hook_gh_watch_pass). They live here, outside the lazily
# loaded library, so a command that matches none of them never loads it:
# only `git ... push`, `git ... pr-open|pr-submit|pr-restack|pr-sync-stack`
# (or its dashed `git-pr-*` form), or `gh ... pr` in command position (line
# start or after a shell separator or quote, optionally behind assignments
# or common wrappers) goes on to the command classifier, so long text that
# merely mentions the words stays cheap.
# A bare pull-request URL line from any GitHub host. Host, owner, and
# repository are limited to name characters: a recorded URL is echoed into a
# suggested command.
_HOOK_GH_PR_URL_RE='https://[A-Za-z0-9.-]+/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/pull/[0-9]+[[:space:]]*$'
_hook_gh_prefilter_separators=$';&|(`"\'\n'
_hook_gh_prefilter_wrappers='[[:alpha:]_][[:alnum:]_]*=[^[:space:]]*|sudo|env|command|nohup|exec|xargs|timeout[[:blank:]]+[^[:space:]]+'
_hook_gh_prefilter_lead="(^|[${_hook_gh_prefilter_separators}]|\\\$\\()[[:blank:]]*((${_hook_gh_prefilter_wrappers})[[:blank:]]+)*"
_HOOK_GH_PREFILTER_GIT_PUSH="${_hook_gh_prefilter_lead}git([[:blank:]]+[^[:space:]]+)*[[:blank:]]+push([[:space:]]|$)"
_HOOK_GH_PREFILTER_GIT_PR="${_hook_gh_prefilter_lead}(git([[:blank:]]+[^[:space:]]+)*[[:blank:]]+|([^[:space:]]*/)?git-)pr-(open|submit|restack|sync-stack)([[:space:]]|$)"
_HOOK_GH_PREFILTER_GH_PR="${_hook_gh_prefilter_lead}gh([[:blank:]]+[^[:space:]]+)*[[:blank:]]+pr[[:space:]]"
unset _hook_gh_prefilter_separators _hook_gh_prefilter_wrappers _hook_gh_prefilter_lead

# Whether command text $1 may run a command that starts pull-request checks
# (builtin regexes only; the classifier decides). The `git pr-*` regex sits
# behind a substring match: it costs milliseconds on a long command, and
# almost no command names these.
_hook_gh_watch_prefilter() {
  [[ "$1" =~ $_HOOK_GH_PREFILTER_GIT_PUSH ]] && return 0
  case "$1" in
    *pr-open* | *pr-submit* | *pr-restack* | *pr-sync-stack*)
      [[ "$1" =~ $_HOOK_GH_PREFILTER_GIT_PR ]] && return 0
      ;;
  esac
  [[ "$1" =~ $_HOOK_GH_PREFILTER_GH_PR ]]
}

# Uses the command classifier to change into a leading `cd` target. Used by
# pre-bash and post-bash local `-work` variants to resolve repo context when
# the agent's command starts with cd. No-op if the first top-level command
# fragment is not cd or the directory doesn't exist.
_hook_cd_to_target() {
  local fragment="" fragments target_dir

  _hook_load_command_classifier || return 0

  fragments="$(_hook_command_fragments "$AGENTGUARD_CMD_TRIMMED")" || return 0
  IFS= read -r fragment <<<"$fragments"
  [ -n "$fragment" ] || return 0

  target_dir=$(_fragment_initial_cd_target "$fragment") || return 0
  target_dir="$(_hook_resolve_dir "$PWD" "$target_dir")" || return 0
  cd "$target_dir" || return 0
}

# --- Hive Memory integration ---

_hook_hm_resolve_config() {
  local base

  # Match Hive Memory's own precedence exactly. An explicitly set override is
  # authoritative even when it is empty or relative, so availability must not
  # silently fall through to another config. XDG base directories, unlike
  # tool-specific path overrides, are valid only when absolute.
  if [ -n "${HIVE_MEMORY_CONFIG+x}" ]; then
    _HOOK_HM_CONFIG_PATH="$HIVE_MEMORY_CONFIG"
    return 0
  fi

  case "${XDG_CONFIG_HOME:-}" in
    /*) base="${XDG_CONFIG_HOME%/}" ;;
    *)
      [ -n "${HOME:-}" ] || return 1
      base="${HOME%/}/.config"
      ;;
  esac
  _HOOK_HM_CONFIG_PATH="$base/hive-memory/config.toml"
}

_hook_hm_available() {
  # Tests and emergency debugging can disable Hive Memory without changing the
  # installed hook config. Production defaults to enabled so memory context is
  # automatic once `hm` and its config are present.
  [ "${AGENTGUARD_HIVE_MEMORY_HOOKS:-1}" != "0" ] || return 1
  # `hm hook` may run lower-level `hm` maintenance commands. If those commands
  # themselves trigger agent hooks, skip here so a refresh/render cycle cannot
  # recursively call back into Hive Memory.
  [ "${HIVE_MEMORY_HOOK_ACTIVE:-0}" != "1" ] || return 1
  command -v hm >/dev/null 2>&1 || return 1
  _hook_hm_resolve_config || return 1
  [ -n "$_HOOK_HM_CONFIG_PATH" ] || return 1
  [ -f "$_HOOK_HM_CONFIG_PATH" ] || return 1
}

_hook_hm_read_input() {
  _hook_read_input || return 0
}

_hook_hm_project_hint_is_home() {
  local hint="${1%/}" home="${HOME:-}"
  home="${home%/}"
  [ -n "$home" ] && [ "$hint" = "$home" ]
}

_hook_hm_project_hint() {
  _hook_hm_read_input
  if [ -n "${_HOOK_INPUT+x}" ]; then
    local hint
    hint=$(printf '%s' "$_HOOK_INPUT" | jq -r '
      [
        .tool_input.file_path?,
        .tool_input.path?,
        .tool_input.cwd?,
        .toolInput.file_path?,
        .toolInput.path?,
        .toolInput.cwd?,
        .cwd?,
        .workspaceRoot?,
        .workspace.current_dir?,
        .project_dir?
      ] | map(select(type == "string" and . != "")) | .[0] // empty
    ' 2>/dev/null)
    [ -n "$hint" ] && {
      _hook_hm_project_hint_is_home "$hint" && return 0
      printf '%s\n' "$hint"
      return 0
    }
  fi
  local cwd
  cwd=$(pwd) || return 0
  _hook_hm_project_hint_is_home "$cwd" && return 0
  printf '%s\n' "$cwd"
}

_hook_hm_prompt_text() {
  _hook_hm_read_input
  printf '%s' "${_HOOK_INPUT:-}" | jq -r '
    [
      .prompt?,
      .user_prompt?,
      .message?,
      .input?,
      .tool_input.prompt?,
      .toolInput.prompt?
    ]
    | map(select(type == "string" and . != ""))
    | .[0] // empty
  ' 2>/dev/null
}

_hook_hm_tool_status() {
  _hook_hm_read_input
  local status _status_agent _status_muse=''
  _hook_agent_name _status_agent
  [ "$_status_agent" != muse ] ||
    _status_muse="(.tool_response? | strings | $_HOOK_MUSE_ENVELOPE_JQ | $_HOOK_MUSE_STATUS_JQ) //"
  status=$(printf '%s' "${_HOOK_INPUT:-}" | jq -r '
    # A negative code (a signal number reported as -N) is still a failure.
    def status_code(v):
      if v == null then empty
      elif (v | type) == "number" then (if v < 0 then 1 else v end)
      elif (v | type) == "string" then
        (v | ascii_downcase) as $s |
        if ($s | test("^[0-9]+$")) then ($s | tonumber)
        elif ($s | test("^-[0-9]+$")) then 1
        elif (["success", "succeeded", "ok", "pass", "passed"] | index($s)) then 0
        elif (["failure", "failed", "error", "errored", "fail"] | index($s)) then 1
        else empty end
      elif (v | type) == "boolean" then
        if v then 1 else 0 end
      else empty end;
    # `?` on the object lookups: a string tool_response (Codex, Muse) has no
    # fields, and an unguarded lookup would fail the whole program.
    '"$_status_muse"' .tool_response.exit_code?
    // .tool_response.status?
    // .tool_result.exit_code?
    // .tool_result.status?
    // .toolResult.exit_code?
    // .toolResult.status?
    // .tool_result_is_error
    // .status
    // 0
    | status_code(.) // 0
  ' 2>/dev/null) || status=''

  case "$status" in
    '' | *[!0-9]*)
      printf '0\n'
      ;;
    *)
      printf '%s\n' "$status"
      ;;
  esac
}

_hook_hm_apply_response() {
  local response="$1"
  local warning action kind body

  while IFS= read -r warning; do
    [ -n "$warning" ] || continue
    _hook_warn "Hive Memory: $warning"
  done < <(printf '%s' "$response" | jq -r '.warnings[]? // empty' 2>/dev/null)

  while IFS= read -r action; do
    [ -n "$action" ] || continue
    kind=$(printf '%s' "$action" | jq -r '.kind // empty' 2>/dev/null)
    body=$(printf '%s' "$action" | jq -r '.body // empty' 2>/dev/null)
    [ -n "$body" ] || continue
    case "$kind" in
      inject_context)
        _HOOK_HM_CONTEXT_EMITTED=1
        if [ -n "$_HOOK_HM_TRACKED" ]; then
          # Remember exactly where the memory context lands so _hook_finish
          # can drop it again if the final output would exceed the host limit.
          _HOOK_HM_CTX_PREFIX="$_HOOK_CTX"
          _HOOK_HM_CTX_BODY="$body"
        fi
        _hook_context "$body"
        ;;
      remind)
        _hook_remind "$body"
        ;;
      *)
        _hook_warn "Hive Memory returned unknown hook action: $kind"
        ;;
    esac
  done < <(printf '%s' "$response" | jq -c '.actions[]?' 2>/dev/null)
}

_hook_hm_warn_once() {
  local key="$1" message="$2"
  # Hook failures should be visible, but not repeated after every tool call in
  # a long-lived session if a sync mount or config is temporarily unavailable.
  _hook_once_per_session "hm-warn-$key" && _hook_warn "$message"
}

# Inline `bash -c` script backing _hook_timeout_prefix's fallback when
# neither a GNU-compatible `timeout` nor `gtimeout` is on PATH. That includes
# stock macOS (no coreutils) and BusyBox: BusyBox reports a timed-out child as
# status 143 instead of GNU's 124, so callers cannot distinguish the timeout
# from an independently SIGTERM-terminated command. Takes the budget in
# seconds as $1 and the guarded command as the rest. A one-shot sleep measures
# wall time independently of scheduler delays; its watchdog signals this
# wrapper, which TERMs then KILLs the child and exits 124 to match GNU timeout's
# convention. Both child processes are reaped on every exit path so a completed
# command cannot leave its timer behind. Must be a
# real executable (not a shell function) so it works as a plain word in
# _HOOK_TIMEOUT_PREFIX even when a caller execs it via `env` (env can only
# exec real binaries, not the calling shell's functions) — `bash` itself is
# always present since this whole library requires it already, so this adds
# no new dependency.
# shellcheck disable=SC2016 # single-quoted on purpose: expands later, inside the bash -c it's passed to.
_HOOK_PORTABLE_TIMEOUT_SCRIPT='
  seconds="$1"; shift
  target_pid=""
  target_pgid=""
  watchdog_pid=""
  timed_out=0
  timer_failed=0

  # GNU timeout treats a zero duration as disabling the timeout. Preserve that
  # contract before creating a process group or watchdog in the fallback.
  if [[ "$seconds" =~ ^0*([.]0*)?$ ]]; then
    exec "$@"
  fi

  stop_target() {
    [ -n "$target_pgid" ] || return 0
    kill -TERM -- "-$target_pgid" 2>/dev/null || return 0
    # The PATH sleep may be the failing timer backend; this grace is advisory.
    sleep 0.1 || true
    kill -KILL -- "-$target_pgid" 2>/dev/null || true
  }

  stop_watchdog() {
    [ -n "$watchdog_pid" ] || return 0
    kill -TERM "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
    watchdog_pid=""
  }

  cleanup() {
    trap - EXIT
    # Cleanup is idempotent and owns both child lifecycles. Ignore repeated
    # signals until they are reaped; restoring defaults here lets a second
    # signal kill the wrapper between TERM and KILL and strand its children.
    trap "" HUP INT QUIT TERM USR1 USR2
    stop_watchdog
    stop_target
    [ -n "$target_pid" ] && wait "$target_pid" 2>/dev/null || true
  }

  expire() {
    timed_out=1
    stop_target
  }

  timer_error() {
    timer_failed=1
    stop_target
  }

  trap cleanup EXIT
  trap "exit 129" HUP
  trap "exit 130" INT
  trap "exit 131" QUIT
  trap "exit 143" TERM
  trap expire USR1
  trap timer_error USR2

  # Monitor mode gives this one asynchronous job a distinct process group on
  # Bash 3.2 and newer without requiring GNU `setsid`. Descendants inherit that
  # group, so timeout and interruption cleanup cannot strand grandchildren.
  # Restore the inherited monitor option inside the child before exec so an
  # exported SHELLOPTS value remains identical to direct execution.
  monitor_was_on=0
  case $- in
    *m*) monitor_was_on=1 ;;
  esac
  set -m
  (
    [ "$monitor_was_on" -eq 1 ] || set +m
    exec "$@"
  ) &
  target_pid=$!
  target_pgid=$target_pid
  [ "$monitor_was_on" -eq 1 ] || set +m
  wrapper_pid=$$

  (
    timer_pid=""
    stop_timer() {
      # As in wrapper cleanup, the first signal owns cleanup to completion.
      trap "" HUP INT QUIT TERM
      [ -n "$timer_pid" ] && kill -TERM "$timer_pid" 2>/dev/null || true
      [ -n "$timer_pid" ] && wait "$timer_pid" 2>/dev/null || true
      exit 0
    }
    trap stop_timer HUP INT QUIT TERM
    sleep "$seconds" &
    timer_pid=$!
    if wait "$timer_pid"; then
      timer_status=0
    else
      timer_status=$?
    fi
    if [ "$timer_status" -eq 0 ]; then
      kill -USR1 "$wrapper_pid" 2>/dev/null || true
    else
      kill -USR2 "$wrapper_pid" 2>/dev/null || true
    fi
  ) &
  watchdog_pid=$!

  if wait "$target_pid"; then
    target_status=0
  else
    target_status=$?
  fi
  if [ "$timed_out" -eq 1 ] || [ "$timer_failed" -eq 1 ]; then
    wait "$target_pid" 2>/dev/null || true
  fi
  target_pid=""
  stop_watchdog
  trap - EXIT HUP INT QUIT TERM USR1 USR2

  [ "$timed_out" -eq 0 ] || exit 124
  [ "$timer_failed" -eq 0 ] || exit 125
  exit "$target_status"
'

# Best-effort external timeout guard for a slow subprocess, general-purpose
# (not Hive Memory-specific). Sets the _HOOK_TIMEOUT_PREFIX array to prepend
# to the guarded command, preferring a GNU-compatible `timeout`/`gtimeout`
# binary and falling back to the portable bash implementation above so every
# platform exposes the same status-124 timeout contract.
_hook_timeout_prefix() {
  local seconds="$1" timeout_help=''

  # Own the duration grammar before selecting a backend so GNU extensions do
  # not behave differently from stock macOS or BusyBox. The status-only prefix
  # ignores every appended target argument and therefore cannot execute it.
  if [[ ! "$seconds" =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]]; then
    _HOOK_TIMEOUT_PREFIX=(bash -c 'exit 125' _)
    return 0
  fi

  # Backend probing shells out (`timeout --help`); the answer depends only on
  # PATH, so cache it per process and re-probe only when PATH changes.
  if [ "${_HOOK_TIMEOUT_BACKEND_PATH:-}" != "${PATH:-}" ]; then
    _HOOK_TIMEOUT_BACKEND_PATH="${PATH:-}"
    if command -v timeout >/dev/null 2>&1; then
      timeout_help=$(timeout --help 2>&1 || true)
      if [[ "$timeout_help" == *BusyBox* ]]; then
        _HOOK_TIMEOUT_BACKEND=portable
      else
        _HOOK_TIMEOUT_BACKEND=gnu
      fi
    elif command -v gtimeout >/dev/null 2>&1; then
      _HOOK_TIMEOUT_BACKEND=gtimeout
    else
      _HOOK_TIMEOUT_BACKEND=portable
    fi
  fi

  case "$_HOOK_TIMEOUT_BACKEND" in
    gnu) _HOOK_TIMEOUT_PREFIX=(timeout "$seconds") ;;
    gtimeout) _HOOK_TIMEOUT_PREFIX=(gtimeout "$seconds") ;;
    *) _HOOK_TIMEOUT_PREFIX=(bash -c "$_HOOK_PORTABLE_TIMEOUT_SCRIPT" _ "$seconds") ;;
  esac
}

_hook_hm_event() {
  # 125 until hm actually ran: a context reset that could not reach `hm` must
  # not count as recorded.
  _HOOK_HM_LAST_RC=125
  _hook_hm_available || return 0

  local event="$1"
  shift
  local project="" err rc project_infer=1
  local -a hm_args
  _hook_hm_read_input
  err=$(mktemp "${TMPDIR:-/tmp}/hm-hook.XXXXXX") || return 0

  # Keep hook scripts policy-light: they pass event facts, and `hm` resolves
  # agent identity, project/store affinity, context freshness, and refresh
  # coalescing from config and hook state.
  hm_args=(hook "$event")
  case "$event" in
    stop | tool-complete | context-reset)
      # Intentionally omit project context for these events. `session-start`
      # and `prompt-submit` are the project-aware context boundaries;
      # `tool-complete` only reports status, and passing a project hint here
      # forces `hm` through VCS discovery after every tool call.
      project_infer=0
      ;;
    *)
      project=$(_hook_hm_project_hint)
      if [ -n "$project" ]; then
        hm_args+=(--project "$project")
      else
        project_infer=0
      fi
      ;;
  esac
  hm_args+=(--json "$@")

  # `hm`'s canonical store for a given alias can be a network-backed mount
  # (e.g. an rclone/cloud-synced Google Drive path) with no latency bound of
  # its own. Guard the call with a short external timeout so a slow or
  # unreachable store degrades to "skip memory context this turn" well
  # inside the hook runner's own timeout budget, instead of risking the
  # whole hook process getting killed later and its output discarded.
  _hook_timeout_prefix "${AGENTGUARD_HIVE_MEMORY_TIMEOUT:-2}"

  _hook_hm_run "$err" "$project_infer" "$project" "${hm_args[@]}" \
    ${_HOOK_HM_DELIVERY_ARGS[@]+"${_HOOK_HM_DELIVERY_ARGS[@]}"}
  rc=$?
  if [ "$rc" -eq 2 ] && [ "${#_HOOK_HM_DELIVERY_ARGS[@]}" -gt 0 ]; then
    # `hm` exits 2 only for command-line usage errors, so an installed `hm`
    # older than delivery tracking rejects the optional flags this way. Run
    # the untracked command it understands instead of losing memory context.
    _hook_hm_note_once "untracked" "Hive Memory predates delivery tracking; using untracked hooks"
    _HOOK_HM_DELIVERY_ARGS=()
    _HOOK_HM_TRACKED=''
    _hook_hm_run "$err" "$project_infer" "$project" "${hm_args[@]}"
    rc=$?
  fi
  # Delivery arguments belong to this one event.
  _HOOK_HM_DELIVERY_ARGS=()
  _HOOK_HM_LAST_RC=$rc
  # A tracked call can fail after `hm` recorded its output as delivered (the
  # timeout guard killing it, for example), and the output is discarded here:
  # leave a reset pending so the next prompt re-sends.
  [ "$rc" -eq 0 ] || [ -z "$_HOOK_HM_TRACKED" ] || _hook_hm_mark_dirty
  if [ "$rc" -ne 0 ] && [ -n "$_HOOK_HM_QUIET" ]; then
    # Hooks whose response cannot carry context (PreCompact) report on stderr
    # and telemetry only, under their own once-keys, so they never use up the
    # once-per-session warnings a later prompt would show the model.
    if [ "$rc" -eq 2 ]; then
      _hook_hm_note_once "untracked-$event" "Hive Memory predates $event; context loss will be retried"
    else
      _hook_hm_note_once "failed-$event" "Hive Memory $event failed with status $rc"
    fi
    rm -f "$err"
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" -eq 124 ]; then
      _hook_hm_warn_once "timeout" "Hive Memory hook timed out after ${AGENTGUARD_HIVE_MEMORY_TIMEOUT:-2}s — skipping memory context this turn"
    elif [ -s "$err" ]; then
      _hook_hm_warn_once "failed" "Hive Memory hook failed: $(tr '\n' ' ' <"$err")"
    else
      _hook_hm_warn_once "failed" "Hive Memory hook failed with status $rc"
    fi
    rm -f "$err"
    return 0
  fi
  rm -f "$err"

  _hook_hm_apply_response "$_HOOK_HM_RESPONSE"
}

# Run one `hm` command with the hook environment and the timeout prefix from
# _hook_timeout_prefix. Stores stdout in _HOOK_HM_RESPONSE, stderr in file $1,
# and returns hm's status. $2 is 0 to disable project inference, $3 the project
# hint; the rest is the hm argument list.
_hook_hm_run() {
  local err="$1" project_infer="$2" project="$3"
  shift 3
  if [ "$project_infer" -eq 0 ]; then
    _HOOK_HM_RESPONSE=$(
      env -u HIVE_MEMORY_PROJECT \
        HIVE_MEMORY_CONFIG="$_HOOK_HM_CONFIG_PATH" \
        HIVE_MEMORY_AGENT_ID="$(_hook_agent_name)" \
        HIVE_MEMORY_SESSION_ID="$_HOOK_SESSION_KEY" \
        HIVE_MEMORY_PROJECT_INFER=0 \
        HIVE_MEMORY_HOOK_ACTIVE=1 \
        HIVE_MEMORY_BACKGROUND_REFRESH=1 \
        "${_HOOK_TIMEOUT_PREFIX[@]}" hm "$@" 2>"$err"
    )
  else
    _HOOK_HM_RESPONSE=$(
      HIVE_MEMORY_CONFIG="$_HOOK_HM_CONFIG_PATH" \
        HIVE_MEMORY_AGENT_ID="$(_hook_agent_name)" \
        HIVE_MEMORY_SESSION_ID="$_HOOK_SESSION_KEY" \
        HIVE_MEMORY_PROJECT="$project" \
        HIVE_MEMORY_PROJECT_INFER="$project_infer" \
        HIVE_MEMORY_HOOK_ACTIVE=1 \
        HIVE_MEMORY_BACKGROUND_REFRESH=1 \
        "${_HOOK_TIMEOUT_PREFIX[@]}" hm "$@" 2>"$err"
    )
  fi
}

# Stderr and telemetry only, once per session: operational notes the model
# does not need, unlike _hook_hm_warn_once, which also reaches hook context.
_hook_hm_note_once() {
  _hook_once_per_session "hm-note-$1" || return 0
  _hook_telemetry_note _HOOK_TELEMETRY_WARNINGS "$2"
  printf 'WARNING: %s\n' "$2" >&2
}

# --- Hive Memory delivery tracking ---
#
# With tracking, `hm` skips memories the model can still see: a memory counts
# as delivered once `hm` emits it within the host's size limit. That is safe
# only when every way the host can lose context is reported to `hm`, so
# tracking is enabled per runtime, for runtimes whose signals were verified
# live (2026-10-13; Claude Code 2.1.291, Codex 0.159.3, Muse 1.4.8):
#   - Claude Code keeps hook context in the transcript until compaction
#     (PreCompact, then SessionStart source=compact) or /clear (a new session
#     id, SessionStart source=clear). Hook additionalContext over 10,000
#     characters is replaced by a 2 KB preview, so it is not visible.
#   - Codex keeps context the same way; PreCompact fires at compaction and
#     SessionStart source=compact|clear|resume at the next prompt. No size
#     limit up to 200,000 characters.
#   - Muse replaces prompt-submit context on every turn (lifetime `turn`);
#     session-start context persists through compaction and resume, so
#     compaction needs no reset, and /clear starts a new session id. Hook
#     stdout over 16,384 bytes is dropped whole.
# Other runtimes stay untracked.

# Whether this hook belongs to the context window the hm session key names.
# A subagent (payload agent_id), or a nested agent that inherited its parent's
# session variables (payload session id differs from the key), has a separate
# context window and must not share the parent's delivered set.
_hook_hm_owns_session() {
  [ -n "$_HOOK_INPUT_SESSION" ] && [ "$_HOOK_INPUT_SESSION" = "$_HOOK_SESSION_KEY" ] ||
    return 1
  case "${_HOOK_INPUT:-}" in
    *'"agent_id"'* | *'"agentId"'*)
      if printf '%s' "$_HOOK_INPUT" |
        jq -e '(.agent_id // .agentId // "") | . != ""' >/dev/null 2>&1; then
        return 1
      fi
      ;;
  esac
}

# Set the delivery policy for hm event $1 (session-start, prompt-submit,
# context-reset): _HOOK_HM_LIFETIME, _HOOK_HM_LIMIT_KIND (`context`: bytes of
# additionalContext; `stdout`: bytes of the whole response; empty: no limit),
# and _HOOK_HM_LIMIT. Returns 1 when this hook must stay untracked.
_hook_hm_delivery_policy() {
  local event="$1"
  _HOOK_HM_LIFETIME=''
  _HOOK_HM_LIMIT_KIND=''
  _HOOK_HM_LIMIT=''
  _HOOK_HM_EVENT="$event"
  case "$event" in
    session-start) _HOOK_HM_EVENT_NAME=SessionStart ;;
    prompt-submit) _HOOK_HM_EVENT_NAME=UserPromptSubmit ;;
    *) _HOOK_HM_EVENT_NAME='' ;;
  esac
  case "${AGENTGUARD_HIVE_MEMORY_DELIVERY:-1}" in
    0 | false | no | off) return 1 ;;
  esac
  _hook_hm_owns_session || return 1
  [ -n "$_HOOK_HM_POLICY_AGENT" ] || _hook_agent_name _HOOK_HM_POLICY_AGENT
  case "$_HOOK_HM_POLICY_AGENT" in
    claude)
      _HOOK_HM_LIFETIME=persistent
      _HOOK_HM_LIMIT_KIND=context
      _HOOK_HM_LIMIT=10000
      ;;
    codex)
      _HOOK_HM_LIFETIME=persistent
      ;;
    muse)
      case "$event" in
        prompt-submit) _HOOK_HM_LIFETIME=turn ;;
        # Compaction keeps Muse's session-start context and prompt context
        # never outlives its turn, so nothing visible is lost: a reset would
        # only re-send startup context on every later prompt.
        context-reset) return 1 ;;
        *) _HOOK_HM_LIFETIME=persistent ;;
      esac
      _HOOK_HM_LIMIT_KIND=stdout
      _HOOK_HM_LIMIT=16384
      ;;
    *) return 1 ;;
  esac
}

# Store in the variable named by $2 the size of text $1 in the host limit's
# units: bytes for `context` limits, bytes once escaped as a JSON string for
# `stdout` limits (Muse counts the raw JSON response).
_hook_hm_size() {
  local LC_ALL=C size
  if [ "$_HOOK_HM_LIMIT_KIND" = stdout ] && [ -n "$1" ]; then
    size=$(printf '%s' "$1" | jq -Rs . | wc -c) || size=''
    size=${size//[!0-9]/}
    # jq adds two quotes and a newline.
    size=$((${size:-0} > 3 ? ${size:-0} - 3 : 0))
  else
    size=${#1}
  fi
  printf -v "$2" '%s' "$size"
}

# Per-event file (in the session state dir, suffixed with the hm event) with
# three numbers: the tail, in limit units, recorded from the last response
# whose context after Hive Memory's block (extension reminders, for example)
# pushed it over the host limit; 1 if the last tracked response with a memory
# block overflowed, else 0; and the overflows since the file was last
# forgotten. An accepted reset (_hook_hm_session_start) forgets it; a Muse
# project-change block (_hook_hm_prompt_submit) forgets only the tail, so the
# overflow count still bounds drops on Muse, which has no reset event.
_HOOK_HM_TAIL_PREFIX=hm-context-tail-
# After this many overflows the event stays untracked until the file is
# forgotten. Each overflow costs a dropped memory block and a re-send, so this
# bounds the cost however the tail varies; untracked output is today's.
_HOOK_HM_MAX_OVERFLOWS=3
# Smallest useful budget, in limit units. Below it the prompt runs untracked:
# a tracked block would carry little or nothing, while untracked output at
# least behaves like today (Claude shows a preview of oversized context).
_HOOK_HM_BUDGET_FLOOR=2048

# Read the tail file for the current hm event into the caller's `tail`,
# `overflowed`, and `overflows` variables (0 when missing or malformed).
_hook_hm_read_tail() {
  local LC_ALL=C
  tail=0 overflowed=0 overflows=0
  { read -r tail overflowed overflows <"$_HOOK_STATE_DIR/$_HOOK_HM_TAIL_PREFIX$_HOOK_HM_EVENT"; } \
    2>/dev/null || true
  case "$tail" in '' | *[!0-9]* | ??????*) tail=0 ;; esac
  case "$overflowed" in 1) ;; *) overflowed=0 ;; esac
  case "$overflows" in '' | *[!0-9]* | ???*) overflows=0 ;; esac
}

# Store in the variable named by $1 the largest memory context to request
# from `hm` so the final response stays inside the host limit: the limit minus
# context already present, the recorded tail for this event, and the optional
# AGENTGUARD_HIVE_MEMORY_CONTEXT_RESERVE floor. Returns 1 when the host has no
# limit, and 2 when this event should run untracked (too many overflows, or a
# budget under _HOOK_HM_BUDGET_FLOOR).
#
# There is no tail allowance until a response actually overflows. Untracked
# hooks overflow then too whenever the tracked block is a subset of theirs:
# session start and Muse context-change prompts. Claude/Codex prompts that add
# recall and Muse recall can be larger and cost one drop. Each overflow
# (_hook_hm_finalize_delivery) records its tail, and the next budget leaves
# room for it. A first tail over half the limit is recorded as half, so a
# one-off huge reminder still leaves room for memory; only consecutive
# overflows record it whole. The last overflow replaces the recorded tail, so
# it can shrink again. Drops are bounded by _HOOK_HM_MAX_OVERFLOWS, after
# which the event runs untracked until the tail is forgotten.
_hook_hm_context_budget() {
  local LC_ALL=C used=0 tail overflowed overflows reserve allowance envelope
  reserve="${AGENTGUARD_HIVE_MEMORY_CONTEXT_RESERVE:-0}"
  case "$reserve" in
    '' | *[!0-9]* | ??????*) reserve=0 ;;
  esac
  reserve=$((10#$reserve))
  case "$_HOOK_HM_LIMIT_KIND" in
    context) envelope=0 ;;
    stdout)
      # The strict-agent response around additionalContext, plus jq's
      # trailing newline (_hook_finish).
      envelope='{"hookSpecificOutput":{"hookEventName":"","additionalContext":""}}'
      envelope=$((${#envelope} + ${#_HOOK_HM_EVENT_NAME} + 1))
      ;;
    *) return 1 ;;
  esac
  _hook_hm_read_tail
  [ "$overflows" -lt "$_HOOK_HM_MAX_OVERFLOWS" ] || return 2
  [ "$reserve" -gt "$tail" ] && tail=$reserve
  [ -n "$_HOOK_CTX" ] && _hook_hm_size "$_HOOK_CTX"$'\n' used
  # The host drops a response at the limit, so stay one unit below. `hm`
  # counts JSON escaping the way jq does, so no further margin is needed.
  allowance=$((_HOOK_HM_LIMIT - 1 - envelope - used - tail))
  [ "$allowance" -ge "$_HOOK_HM_BUDGET_FLOOR" ] || return 2
  # The caller names its own variable; no local here may share that name.
  printf -v "$1" '%s' "$allowance"
}

# Prepare tracked delivery from the policy _hook_hm_delivery_policy just set;
# arguments (--reset) are passed through to `hm`. Returns 1, leaving the call
# untracked, when _hook_hm_context_budget says this event should run untracked.
_hook_hm_track() {
  local budget status=0
  _hook_hm_context_budget budget || status=$?
  if [ "$status" -eq 2 ]; then
    _hook_telemetry_note _HOOK_TELEMETRY_WARNINGS \
      "Hive Memory context untracked: too little room under the host limit"
    return 1
  fi
  _HOOK_HM_TRACKED=1
  _HOOK_HM_DELIVERY_ARGS=(--delivery "$_HOOK_HM_LIFETIME" "$@")
  if [ "$status" -eq 0 ]; then
    _HOOK_HM_DELIVERY_ARGS+=(--max-context-bytes "$budget")
    [ "$_HOOK_HM_LIMIT_KIND" = stdout ] && _HOOK_HM_DELIVERY_ARGS+=(--context-size json)
  fi
  return 0
}

# Return 0 when the last tracked `hm` call succeeded and emitted memory
# context: memories, pointers, or a header-only block (all memories already
# visible). Callers reset _HOOK_HM_CONTEXT_EMITTED before the call.
_hook_hm_emitted_context() {
  [ -n "$_HOOK_HM_TRACKED" ] && [ "$_HOOK_HM_LAST_RC" -eq 0 ] &&
    [ "$_HOOK_HM_CONTEXT_EMITTED" -eq 1 ]
}

# Forget every recorded tail and overflow count (a new context epoch).
_hook_hm_forget_tail() {
  rm -f "$_HOOK_STATE_DIR/$_HOOK_HM_TAIL_PREFIX"* 2>/dev/null || true
}

# Marker (in the session state dir) for a context loss `hm` has not recorded
# yet: a reset that failed (timeout, lock contention) must still happen before
# anything is skipped as already visible.
_HOOK_HM_DIRTY_MARKER=hm-context-dirty

_hook_hm_mark_dirty() {
  # No marker where Hive Memory is off or not installed; a configured hm that
  # was briefly unreachable still gets one.
  [ "${AGENTGUARD_HIVE_MEMORY_HOOKS:-1}" != "0" ] || return 0
  command -v hm >/dev/null 2>&1 || return 0
  _hook_mkstate "$_HOOK_STATE_DIR" || return 0
  : >"$_HOOK_STATE_DIR/$_HOOK_HM_DIRTY_MARKER" 2>/dev/null || true
}

# Called from _hook_finish. Re-checks the host limit against the final
# context and keeps the tail file current. `hm` already counted the memory
# context as delivered, so if it would push the response over the limit (the
# host would hide or drop it) it is removed, the context after it is recorded
# as this event's tail, and a context reset is left pending: the next prompt
# re-sends.
_hook_hm_finalize_delivery() {
  [ -n "$_HOOK_HM_TRACKED" ] && [ -n "$_HOOK_HM_CTX_BODY" ] && [ -n "$_HOOK_HM_LIMIT" ] ||
    return 0
  local LC_ALL=C size=0 segment rest='' tail overflowed overflows measured=''
  local half tail_file="$_HOOK_STATE_DIR/$_HOOK_HM_TAIL_PREFIX$_HOOK_HM_EVENT"

  case "$_HOOK_HM_LIMIT_KIND" in
    context) size=${#_HOOK_CTX} ;;
    stdout)
      # Muse counts the raw response, so measure the exact strict-agent JSON
      # (and jq's trailing newline) that _hook_finish prints.
      size=$(printf '%s' "$_HOOK_CTX" |
        jq -Rsc --arg hook_event_name "$(_hook_event_name)" '{
          hookSpecificOutput: {
            hookEventName: $hook_event_name,
            additionalContext: .
          }
        }' | wc -c) || size=''
      size=${size//[!0-9]/}
      [ -n "$size" ] || size=$_HOOK_HM_LIMIT
      ;;
  esac
  _hook_hm_read_tail
  if [ "$size" -lt "$_HOOK_HM_LIMIT" ]; then
    # Fits: only the consecutive-overflow flag changes.
    if [ "$overflowed" = 1 ] && _hook_mkstate "$_HOOK_STATE_DIR"; then
      printf '%s 0 %s\n' "$tail" "$overflows" >"$tail_file" 2>/dev/null || true
    fi
    return 0
  fi
  if [ -n "$_HOOK_HM_CTX_PREFIX" ]; then
    segment="$_HOOK_HM_CTX_PREFIX"$'\n'"$_HOOK_HM_CTX_BODY"
  else
    segment="$_HOOK_HM_CTX_BODY"
  fi
  case "$_HOOK_CTX" in
    "$segment"*)
      rest="${_HOOK_CTX#"$segment"}"
      # The context after the memory block, its leading separator included
      # (none when the block alone overflowed).
      tail=0
      [ -z "$rest" ] || _hook_hm_size "$rest" tail
      measured=1
      [ -n "$_HOOK_HM_CTX_PREFIX" ] || rest="${rest#$'\n'}"
      _HOOK_CTX="$_HOOK_HM_CTX_PREFIX$rest"
      _hook_telemetry_note _HOOK_TELEMETRY_WARNINGS \
        "Hive Memory context dropped: the response would exceed the host limit"
      ;;
  esac
  overflows=$((overflows + 1))
  if [ -z "$measured" ]; then
    # Something rewrote the context around the memory block, so the tail
    # cannot be measured and the next budget could not leave room for it.
    # Fail safe: this event stays untracked until the tail is forgotten.
    overflows=$_HOOK_HM_MAX_OVERFLOWS
  elif [ "$overflowed" != 1 ]; then
    half=$((_HOOK_HM_LIMIT / 2))
    [ "$tail" -le "$half" ] || tail=$half
  fi
  if _hook_mkstate "$_HOOK_STATE_DIR"; then
    printf '%s 1 %s\n' "$tail" "$overflows" >"$tail_file" 2>/dev/null || true
  fi
  _hook_hm_mark_dirty
}

# Called from _hook_finish after the response: memory context `hm` counted as
# delivered that the host will not show (this hook blocked the prompt, or
# writing the response failed) leaves a context reset pending. Turn-lifetime
# context never joins the delivered set, so a reset would recover nothing and
# only re-send context the host still keeps.
_hook_hm_undelivered() {
  [ -n "$_HOOK_HM_TRACKED" ] && [ -n "$_HOOK_HM_CTX_BODY" ] || return 0
  [ "$_HOOK_HM_LIFETIME" != turn ] || return 0
  _hook_hm_mark_dirty
}

_hook_hm_session_start() {
  local marker source='' reset=''
  # Read hook stdin before checking the marker. Some runners only expose the
  # durable session id in JSON; checking the process-key marker first would miss
  # an existing session marker, and writing after _hook_hm_event could target a
  # stale path if reading stdin refreshes _HOOK_STATE_DIR.
  _hook_hm_read_input
  # Codex currently renders hook `additionalContext` visibly even when the hook
  # result also sets suppressOutput. Keep SessionStart useful as an initial
  # memory attach point, but do not inject the same stable-session context after
  # every hook process. PromptSubmit still has its own path for context changes
  # such as a project/store affinity switch.
  marker="$_HOOK_STATE_DIR/hm-session-start-context-emitted"
  if _hook_hm_delivery_policy session-start; then
    case "${_HOOK_INPUT:-}" in
      *'"source"'*)
        source=$(printf '%s' "$_HOOK_INPUT" | jq -r '.source // empty' 2>/dev/null) ||
          source=''
        ;;
    esac
    # Compaction, clear, and resume can remove earlier context from the
    # model's view, so they start a new epoch and re-inject past the marker.
    # The first SessionStart for a key resets too: a reused session key must
    # not inherit another session's delivered set.
    case "$source" in
      compact | clear | resume) reset=1 ;;
      *) [ -e "$marker" ] || reset=1 ;;
    esac
    [ -n "$reset" ] || return 0
    # Untracked when there is too little room; the reset then stays pending.
    _hook_hm_track --reset || true
  else
    [ ! -e "$marker" ] || return 0
  fi

  _HOOK_HM_CONTEXT_EMITTED=0
  _hook_hm_event session-start
  if [ -n "$reset" ]; then
    # Only a tracked call that `hm` accepted recorded the reset; an older
    # `hm` (retried untracked) or an unreachable one did not.
    # The new epoch also forgets recorded tails (see _hook_hm_context_budget).
    # A pending reset is cleared only once memory context went out under it.
    if [ "$_HOOK_HM_LAST_RC" -eq 0 ] && [ -n "$_HOOK_HM_TRACKED" ]; then
      _hook_hm_forget_tail
      if _hook_hm_emitted_context; then
        rm -f "$_HOOK_STATE_DIR/$_HOOK_HM_DIRTY_MARKER" 2>/dev/null || true
      else
        _hook_hm_mark_dirty
      fi
    else
      _hook_hm_mark_dirty
    fi
  fi
  if [ "$_HOOK_HM_CONTEXT_EMITTED" -eq 1 ]; then
    # Warnings also add hook context, but they do not deliver memory. Mark only
    # a real inject_context action so a timeout remains retryable after recovery.
    # _hook_hm_event also reads stdin for callers that did not already do so,
    # so derive the marker path from the post-event state as a final guard.
    marker="$_HOOK_STATE_DIR/hm-session-start-context-emitted"
    _hook_mkstate "$_HOOK_STATE_DIR" || return 0
    : >"$marker" 2>/dev/null || true
  fi
}

_hook_hm_prompt_submit() {
  local prompt dirty=''
  # Read stdin in this shell before extracting the prompt. Command substitution
  # runs helper calls in a subshell, so letting `_hook_hm_prompt_text` perform
  # the first read would consume hook JSON without preserving `_HOOK_INPUT` for
  # agent-specific and local extensions sourced later in this hook.
  _hook_hm_read_input
  prompt=$(_hook_hm_prompt_text)
  [ -n "$prompt" ] || return 0
  _HOOK_PROMPT_SUBMITTED=1
  if _hook_hm_available && _hook_hm_delivery_policy prompt-submit; then
    # Untracked when there is too little room (_hook_hm_track); a pending
    # reset then waits for a tracked prompt.
    if [ -e "$_HOOK_STATE_DIR/$_HOOK_HM_DIRTY_MARKER" ]; then
      dirty=1
      _hook_hm_track --reset || true
    else
      _hook_hm_track || true
    fi
  fi
  _HOOK_HM_CONTEXT_EMITTED=0
  _hook_hm_event prompt-submit --text "$prompt"
  # Clear a pending reset only once a tracked call accepted it and emitted
  # memory context under it (memories, pointers, or a header). An untracked
  # call (older `hm`, or too little room) never sent it, and a response with
  # no context re-sent nothing.
  if [ -n "$dirty" ] && _hook_hm_emitted_context; then
    rm -f "$_HOOK_STATE_DIR/$_HOOK_HM_DIRTY_MARKER" 2>/dev/null || true
  fi
  # A Muse project-change block forgets the recorded tail, so one overflow
  # cannot shrink Muse budgets for the rest of the session (Muse has no reset
  # event that would). The overflow count stays: it is what bounds drops.
  local tail overflowed overflows
  if [ "$_HOOK_HM_LIFETIME" = turn ] && [ -n "$_HOOK_HM_TRACKED" ] &&
    [ "$_HOOK_HM_LAST_RC" -eq 0 ] &&
    printf '%s' "$_HOOK_HM_RESPONSE" |
    jq -e '.context_emitted == true and .recall.reason == "context-selection-changed"' \
      >/dev/null 2>&1; then
    _hook_hm_read_tail
    if [ "$tail" -gt 0 ] || [ "$overflowed" = 1 ]; then
      printf '0 0 %s\n' "$overflows" \
        >"$_HOOK_STATE_DIR/$_HOOK_HM_TAIL_PREFIX$_HOOK_HM_EVENT" 2>/dev/null || true
    fi
  fi
}

# PreCompact: the host is about to drop earlier context. Record the loss so
# no memory is skipped as already visible afterwards. A failed reset leaves
# the dirty marker, which makes the next tracked prompt reset first.
_hook_hm_context_reset() {
  _hook_hm_read_input
  _hook_hm_delivery_policy context-reset || return 0
  _HOOK_HM_QUIET=1
  _hook_hm_event context-reset
  _HOOK_HM_QUIET=''
  [ "$_HOOK_HM_LAST_RC" -eq 0 ] || _hook_hm_mark_dirty
}

# Optional $1 overrides the derived status, for hooks that already know
# whether the tool call failed in a runtime-specific shape.
_hook_hm_tool_complete() {
  local _complete_agent
  # Checked here as well as in _hook_hm_event (both builtin): the status
  # argument below is a `$(...)` jq run, which would otherwise fork on every
  # tool call with Hive Memory off just to be thrown away.
  if ! _hook_hm_available; then
    _HOOK_HM_LAST_RC=125
    return 0
  fi
  # _hook_hm_tool_status reads the runtime inside the `$(...)` below, where a
  # cache miss would fork and its answer would die with the subshell. Every
  # hook resolves the runtime in this shell anyway (_hook_source_extensions),
  # so resolving it here first costs nothing.
  [ -n "${1:-}" ] || _hook_agent_name _complete_agent
  _hook_hm_event tool-complete --status "${1:-$(_hook_hm_tool_status)}"
}

_hook_hm_stop() {
  _hook_hm_event stop
}

# --- Telemetry ---

# Append message $2 to the accumulator named by $1 (record-separator joined).
_hook_telemetry_note() {
  local current="${!1}" message
  _hook_telemetry_field message "$2"
  if [ -n "$current" ]; then
    printf -v "$1" '%s\x1e%s' "$current" "$message"
  else
    printf -v "$1" '%s' "$message"
  fi
}

# Store $2 into the variable named by $1 with the record's ASCII separators
# (unit \x1f between fields, record \x1e between list items) replaced by their
# visible Unicode symbols. Messages, commands, and file names can carry
# agent-controlled bytes; a raw separator would shift every later field and
# let the model forge or hide parts of the audit record.
_hook_telemetry_field() {
  local value="$2"
  value="${value//$'\x1f'/␟}"
  value="${value//$'\x1e'/␞}"
  printf -v "$1" '%s' "$value"
}

# jq program that turns the unit-separated field stream written by
# _hook_telemetry_exit into one schema v1 record. The payload is the last
# field and is re-joined, so a stray separator inside it cannot shift columns.
# Raw payload text travels through stdin, never argv or the environment:
# Linux caps a single argument or variable at 128 KiB, which a PostToolUse
# payload carrying full command output easily exceeds.
# shellcheck disable=SC2016 # jq variables, not shell expansions.
_HOOK_TELEMETRY_JQ='
  def nonempty: select(. != null and . != "" and . != []);
  def list: if . == "" then [] else split("\u001e") end;
  split("\u001f") as $f
  | ($f[7:] | join("\u001f")) as $raw
  | (if $raw == "" then null
     else ($raw | try fromjson catch {unparsed: $raw}) end) as $payload
  | ($payload | if type == "object" then . else {} end) as $p
  | ($sec | tonumber | todate | sub("Z$"; ".\($frac)Z")) as $ts
  | {
      schema: $schema,
      kind: $kind,
      ts: $ts,
      agent: $agent,
      session_key: $key,
      state_key: (if $state_key == $key then null else $state_key end),
      launcher_key: (if $launcher == "" or $launcher == $key or $launcher == $state_key then null else $launcher end),
      session_id: (($p.session_id // $p.sessionId) | if type == "string" then . else null end),
      event: ($p.hook_event_name // $p.hookEventName // (if $event == "" then null else $event end)),
      hook: $hook,
      tool_name: ($p.tool_name // $p.toolName),
      tool_use_id: ($p.tool_use_id // $p.toolUseId // $p.tool_call_id // $p.toolCallId // $p.call_id // $p.callId),
      cwd: ($p.cwd // $pwd),
      host: $host,
      pid: ($pid | tonumber),
      ppid: ($ppid | tonumber),
      exit_status: ($status | tonumber),
      outcome: (if $status == "0" then "ok" elif $status == "2" then "blocked" else "error" end),
      duration_ms: ($duration | tonumber),
      blocked: ($f[0] | list),
      warnings: ($f[1] | list),
      reminders: ($f[2] | list),
      context: $f[3],
      command: $f[4],
      edit_files: ($f[5] | split("\n") | map(select(. != ""))),
      mcp_server: $f[6],
      payload_truncated_chars: (if $truncated == "" or $kind != "event" then null else ($truncated | tonumber) end)
    }
  | with_entries(select(.value | nonempty))
  | if $kind == "event" then . + {payload: $payload} else . end
'

# Reduce the value of the variable named by $1, in place, to a portable path
# component for the telemetry tree: anything outside [[:alnum:]._:-] becomes
# `_`, a leading dot is replaced (dot-directories are invisible to listing
# globs, and `.`/`..` would escape), and the result is capped well below
# NAME_MAX. Session ids are untrusted input (payload JSON, runtime env), and
# the read-side CLI parses tab-separated rows and prints keys to terminals, so
# control characters must never reach a directory name. Real runtime ids
# (UUIDs, `ses_...`, `gemini-<pid>`) already fit and pass through unchanged.
_hook_telemetry_component() {
  # C locale: [[:alnum:]] is ASCII-only and the length cap counts bytes, so
  # the result is the same everywhere and always fits NAME_MAX (a UTF-8
  # locale would keep multibyte letters and could exceed 255 bytes).
  local LC_ALL=C
  local value="${!1}"
  value="${value//[![:alnum:]._:-]/_}"
  case "$value" in
    .*) value="_${value#.}" ;;
  esac
  value="${value:0:128}"
  [ -n "$value" ] || return 1
  printf -v "$1" '%s' "$value"
}

# Store the directory key for this hook's audit records into the variable
# named by $1, for detected agent $2 (no subshell: this runs on every hook
# exit). Guard state keys are tuned so a tool shell and its hooks agree inside
# one live process, which is the wrong trade-off for records kept for months:
#   - Gemini's state key is its CLI pid. Pids recycle within the retention
#     window, and every session `/clear` starts in one process shares it, so
#     unrelated sessions would merge. Gemini puts its real session id in every
#     payload (and in GEMINI_SESSION_ID), so records use that.
#   - Muse's launcher falls back to its pid when MUSE_SESSION_ID is unset, so
#     the payload's session id is preferred there too.
#   - Grok suffixes subagent state keys so concurrent children keep separate
#     circuit breakers. Claude and Muse subagent events carry the parent
#     session id, so Grok records file under the parent too; the child key
#     stays visible as the record's `state_key`.
# The branch follows the detected agent rather than AGENTGUARD_NAME so a
# hand-wired runtime (no identity prefix) is keyed the same way. Every other
# runtime's state key already is its durable session id.
_hook_telemetry_key() {
  local candidate=''
  case "${2:-}" in
    gemini) candidate="${_HOOK_INPUT_SESSION:-${GEMINI_SESSION_ID:-}}" ;;
    muse) candidate="${MUSE_SESSION_ID:-$_HOOK_INPUT_SESSION}" ;;
    grok)
      candidate="${GROK_SESSION_ID:-${AGENTGUARD_SESSION_ID:-}}"
      [ -n "$candidate" ] || candidate="${_HOOK_SESSION_KEY%%:*}"
      ;;
  esac
  [ -n "$candidate" ] || candidate="${_HOOK_SESSION_KEY:-}"
  _hook_telemetry_component candidate || return 1
  printf -v "$1" '%s' "$candidate"
}

# Called from the EXIT trap (_hook_exit): write one audit record for this hook
# invocation. Running from the trap rather than _hook_finish covers every exit
# path, including early no-op exits and fail-closed parse errors, and observes
# the real exit status the host receives.
#
# Record kinds:
#   event — written by agent-hook-telemetry; carries the full host payload.
#   hook  — written by every other hook; carries the decision (exit status,
#           block/warn/remind messages, injected context, parsed command or
#           edit files) but not the payload, which the matching event record
#           already holds. Storing it twice would double the disk cost of
#           large tool outputs.
#
# Telemetry must never change hook behavior: every failure is silent, and the
# caller (_hook_exit) passes the final status and runs this in a subshell.
_hook_telemetry_exit() {
  local status="${1:-$?}" hook kind root agent key dir end_us elapsed duration
  local stem tmp event='' raw='' truncated='' max ctx cmd files server
  _agentguard_telemetry_enabled || return 0
  _agentguard_telemetry_root root 2>/dev/null || return 0
  # Lifecycle hooks may never read stdin (their Hive Memory path skips the
  # read when `hm` is absent). Read it now so the session key comes from the
  # payload, exactly as agent-hook-telemetry's key does; otherwise runtimes
  # whose session id lives only in JSON would file this hook's record under
  # a fallback pid directory. The read is idempotent and bounded.
  if [ -n "${_HOOK_INPUT+x}" ] || [ -z "$_HOOK_INPUT_ATTEMPTED" ]; then
    _hook_read_input >/dev/null 2>&1 || true
  fi
  hook="${_HOOK_SELF:-$0}"
  hook="${hook##*/}"
  if [ "$hook" = "agent-hook-telemetry" ]; then
    kind=event
  else
    kind=hook
    # Fallback only, for hooks that received no payload (the payload's own
    # event name wins in the jq program). _hook_event_name maps to response
    # schema names and defaults unknown hooks to UserPromptSubmit, which would
    # mislabel session-end and notification records, so map explicitly and
    # leave anything unrecognized unnamed.
    case "${hook#agent-hook-}" in
      pre-*) event=PreToolUse ;;
      post-*) event=PostToolUse ;;
      session-start*) event=SessionStart ;;
      session-end*) event=SessionEnd ;;
      prompt-submit*) event=UserPromptSubmit ;;
      compact*) event=PreCompact ;;
      stop*) event=Stop ;;
      notification*) event=Notification ;;
    esac
  fi
  _hook_agent_name agent 2>/dev/null
  # stderr: restoring an uninstalled caller LC_ALL after the helpers' local
  # C locale makes bash print setlocale warnings.
  _hook_telemetry_component agent 2>/dev/null || agent=agent
  _hook_telemetry_key key "$agent" 2>/dev/null || return 0
  dir="$root/sessions/$agent/$key"

  _agentguard_telemetry_now_us end_us
  elapsed=$((end_us - ${_HOOK_TELEMETRY_START_US:-$end_us}))
  [ "$elapsed" -ge 0 ] || elapsed=0
  printf -v duration '%d.%03d' "$((elapsed / 1000))" "$((elapsed % 1000))"

  raw="${_HOOK_INPUT:-}"
  max="${AGENTGUARD_TELEMETRY_MAX_PAYLOAD_CHARS:-8388608}"
  case "$max" in
    # More than 15 digits would overflow `[ -gt ]` on some shells.
    '' | *[!0-9]* | ????????????????*) max=8388608 ;;
  esac
  # Force base 10: a leading zero would otherwise be octal to `${raw:0:max}`
  # (and `08` an error) while `[ -gt ]` reads it as decimal.
  max=$((10#$max))
  if [ "${#raw}" -gt "$max" ]; then
    # Keep a bounded prefix instead of nothing: the record still shows what
    # the call was, and the original length documents the truncation. Hook
    # records only read identity fields from the payload, so the same cap
    # bounds their jq work; a truncated payload no longer parses, which
    # leaves those fields to the event record.
    truncated="${#raw}"
    raw="${raw:0:max}"
  fi

  # Exiting anyway, so neither the restrictive umask nor noclobber can leak
  # into caller state. The umask keeps records (which can hold secrets from
  # tool output) owner-only. A root on a shared path (an override under /tmp,
  # a shared XDG_STATE_HOME) could hold a session directory or temp file that
  # another user pre-planted, so records are only written into a real
  # directory this user owns, and noclobber opens the temp file O_EXCL rather
  # than following a symlink planted at its name.
  umask 077
  set -C
  # Check every directory AgentGuard owns below the root before creating
  # anything inside it (the root itself may legitimately be reached through a
  # user's own symlinked state dir).
  [ -d "$root/sessions" ] || mkdir -p "$root/sessions" 2>/dev/null || [ -d "$root/sessions" ] || return 0
  [ ! -L "$root/sessions" ] && [ -O "$root/sessions" ] || return 0
  [ -d "$root/sessions/$agent" ] || mkdir "$root/sessions/$agent" 2>/dev/null || [ -d "$root/sessions/$agent" ] || return 0
  [ ! -L "$root/sessions/$agent" ] && [ -O "$root/sessions/$agent" ] || return 0
  [ -d "$dir" ] || mkdir "$dir" 2>/dev/null || [ -d "$dir" ] || return 0
  [ ! -L "$dir" ] && [ -O "$dir" ] || return 0
  stem="$end_us-$$-${hook#agent-hook-}"
  tmp="$dir/.$stem.tmp"
  _hook_telemetry_field ctx "$_HOOK_CTX"
  _hook_telemetry_field cmd "${AGENTGUARD_CMD_TRIMMED:-}"
  _hook_telemetry_field files "${AGENTGUARD_EDIT_FILES:-}"
  _hook_telemetry_field server "${_HOOK_MCP_SERVER:-}"
  # The group's stderr redirect also covers a failed `>"$tmp"` open (an
  # unwritable or read-only tree), whose message would otherwise reach the
  # host beside a block reason.
  {
    printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s' \
      "$_HOOK_TELEMETRY_BLOCKS" \
      "$_HOOK_TELEMETRY_WARNINGS" \
      "$_HOOK_TELEMETRY_REMINDERS" \
      "$ctx" \
      "$cmd" \
      "$files" \
      "$server" \
      "$raw" |
      jq -Rsc \
        --arg schema "$_AGENTGUARD_TELEMETRY_SCHEMA" \
        --arg kind "$kind" \
        --arg sec "${end_us:0:${#end_us}-6}" \
        --arg frac "${end_us: -6}" \
        --arg agent "$agent" \
        --arg key "$key" \
        --arg state_key "$_HOOK_SESSION_KEY" \
        --arg launcher "${AGENTGUARD_SESSION_ID:-}" \
        --arg event "$event" \
        --arg hook "$hook" \
        --arg pwd "${PWD:-}" \
        --arg host "${HOSTNAME:-}" \
        --arg pid "$$" \
        --arg ppid "$PPID" \
        --arg status "$status" \
        --arg duration "$duration" \
        --arg truncated "$truncated" \
        "$_HOOK_TELEMETRY_JQ" >"$tmp" &&
      mv -f "$tmp" "$dir/$stem.json"
  } 2>/dev/null
  [ -e "$tmp" ] && rm -f "$tmp" 2>/dev/null
  return 0
}

# --- Agent identification ---

# Returns the name of the running agent. Delegates to the shared
# `_agent_name` detection and falls back to "agent" (not "unknown")
# because in a hook context _something_ is always driving.
#
# Prints the name, or stores it in the variable named by $1. A hook asks
# several times and each `$(...)` ask forked twice, so the answer is cached
# per process, keyed on every variable _agent_name reads; its process-tree
# fallback walks from this shell's own ancestors, which cannot change while
# the hook runs.
_HOOK_AGENT_NAME_KEY=''
_HOOK_AGENT_NAME_VALUE=''

_hook_agent_name() {
  local _agent_name_key='' _agent_name_var _agent_name_value
  # Length-prefixed so no two sets of values can spell the same key.
  for _agent_name_var in AGENTGUARD_NAME CODEX_THREAD_ID CODEX_INTERNAL_ORIGINATOR_OVERRIDE \
    GEMINI_PROJECT_DIR GROK_SESSION_ID CLAUDE_CODE_CURRENT_SESSION_ID CLAUDE_CODE_SESSION_ID \
    AGENT AGENTGUARD_SESSION_ID AGENTGUARD_PROCESS_DETECT; do
    _agent_name_value="${!_agent_name_var-}"
    _agent_name_key+="${#_agent_name_value}:$_agent_name_value"
  done
  if [ -z "$_HOOK_AGENT_NAME_VALUE" ] || [ "$_HOOK_AGENT_NAME_KEY" != "$_agent_name_key" ]; then
    _HOOK_AGENT_NAME_VALUE=$(_agent_name)
    [ "$_HOOK_AGENT_NAME_VALUE" != "unknown" ] || _HOOK_AGENT_NAME_VALUE=agent
    _HOOK_AGENT_NAME_KEY="$_agent_name_key"
  fi
  if [ -n "${1:-}" ]; then
    printf -v "$1" '%s' "$_HOOK_AGENT_NAME_VALUE"
  else
    printf '%s\n' "$_HOOK_AGENT_NAME_VALUE"
  fi
}

# --- Delegation ---

# Sources the `<hook>-<agent>` extension for the detected agent name.
# Auto-discovers by appending the agent name to the hook's own filename
# (e.g., agent-hook-pre-bash-gemini), so any agent identity can have one.
_hook_source_agent() {
  local agent_file _source_agent_name
  _hook_agent_name _source_agent_name
  agent_file="${_HOOK_SELF:-$0}-$_source_agent_name"
  # "agent" is the fallback name and won't match a real file, so
  # the -f check below handles the no-match case cleanly.
  if [ -f "$agent_file" ]; then
    # shellcheck disable=SC1090
    source "$agent_file"
  fi
}

# Sources the -work variant from the same directory as the running hook.
# Uses _HOOK_SELF (set by each base hook before sourcing helpers) so the
# lookup works regardless of how the hook was invoked (PATH, absolute, etc).
_hook_source_work() {
  local work_file="${_HOOK_SELF:-$0}-work"
  if [ -f "$work_file" ]; then
    # shellcheck disable=SC1090
    source "$work_file"
  fi
}

# Sources all extensions in order: agent-specific, then environment-specific.
# Single call point enforces ordering and is easy to extend with new axes.
_hook_source_extensions() {
  _hook_source_agent
  _hook_source_work
}

# Prints the response event name, or stores it in the variable named by $1
# (no `$(...)` fork on the per-call path).
_hook_event_name() {
  # Basename without the fork: hook paths never carry a trailing slash, which
  # is the only input where ${var##*/} and basename(1) disagree.
  local _event_hook_name="${_HOOK_SELF:-$0}" _event_name
  _event_hook_name="${_event_hook_name##*/}"
  case "$_event_hook_name" in
    agent-hook-session-start*) _event_name="SessionStart" ;;
    agent-hook-prompt-submit*) _event_name="UserPromptSubmit" ;;
    agent-hook-pre-*) _event_name="PreToolUse" ;;
    agent-hook-post-*)
      # Post hooks also serve failed tool calls (PostToolUseFailure), and a
      # strict runner rejects a response naming a different event. The
      # payload's top-level event name is cached by the state refresh's jq
      # (a string match could hit a nested object in tool input).
      if [ "$_HOOK_INPUT_EVENT" = "PostToolUseFailure" ]; then
        _event_name="PostToolUseFailure"
      else
        _event_name="PostToolUse"
      fi
      ;;
    agent-hook-stop*) _event_name="Stop" ;;
    agent-hook-compact*) _event_name="PreCompact" ;;
    agent-hook-notification*) _event_name="PermissionRequest" ;;
    *) _event_name="UserPromptSubmit" ;;
  esac
  if [ -n "${1:-}" ]; then
    printf -v "$1" '%s' "$_event_name"
  else
    printf '%s\n' "$_event_name"
  fi
}

_hook_codex_supports_suppress_output() {
  local hook_event_name="$1"

  # Codex validates hook response fields per event. Tool hooks accept
  # additionalContext but currently reject suppressOutput, so keep the
  # suppression knob scoped to quiet lifecycle/context hooks.
  case "$hook_event_name" in
    PreToolUse | PostToolUse) return 1 ;;
    *) return 0 ;;
  esac
}

_hook_finish_codex_stop() {
  # Affected Codex releases assign a local UUID to the synthetic user message
  # created by a Stop continuation, then replay that UUID to the Responses API
  # where message ids must use the `msg_` prefix. The poisoned rollout cannot
  # accept another turn. Prompt hooks already surface reminders before Stop,
  # so keep Stop fail-open until Codex exposes a replay-safe contract.
  printf '{}\n'
}

# Agents whose runners validate hook output strictly. They reject unknown
# top-level fields such as the legacy `context` key and enforce a per-event
# hookSpecificOutput schema, so they receive additionalContext only.
_hook_strict_output_agent() {
  local _strict_agent_name
  _hook_agent_name _strict_agent_name
  case "$_strict_agent_name" in
    codex | muse) return 0 ;;
    *) return 1 ;;
  esac
}

# Emits one JSON response and exits. Must be the last call in every hook.
# Emits legacy "context" for Claude plus Gemini-compatible additionalContext.
# Strict agents (Codex, Muse) use per-event hookSpecificOutput schemas with
# no legacy fields. Only Codex requests suppressOutput; Muse managed hooks
# emit additionalContext alone, and Muse has no documented suppressOutput
# contract, so Muse output stays minimal.
_hook_finish() {
  local _finish_agent_name
  _HOOK_EMITTED=1
  # Handle Codex Stop before the generic context/block branches. A Stop
  # extension can call _hook_block without adding _HOOK_CTX; falling through
  # would still exit 2 and turn stderr into the same replay-unsafe prompt.
  case "${_HOOK_SELF##*/}" in
    agent-hook-stop*)
      _hook_agent_name _finish_agent_name
      if [ "$_finish_agent_name" = "codex" ]; then
        _hook_finish_codex_stop
        exit 0
      fi
      if [ "$_finish_agent_name" = "grok" ]; then
        # Grok Stop additionalContext is non-error keep-working feedback, not
        # a silent annotation. Hive Memory or git context must not retrigger
        # the turn the way a Claude-shaped dual payload would. SubagentStop
        # reuses this launcher (`agent-hook-stop*`), so it stays fail-open
        # empty JSON too.
        printf '{}\n'
        [ -n "$_HOOK_BLOCKED" ] && exit 2
        exit 0
      fi
      ;;
    agent-hook-compact*)
      # PreCompact only records the context loss. Its response schema differs
      # across runtimes and strict runners reject unexpected fields, so a
      # warning stays on stderr and telemetry and the response is empty.
      printf '{}\n'
      exit 0
      ;;
  esac

  _hook_hm_finalize_delivery

  if [ -n "$_HOOK_CTX" ]; then
    if _hook_strict_output_agent; then
      local hook_event_name
      _hook_event_name hook_event_name
      if [ -n "$_HOOK_BLOCKED" ]; then
        printf '%s' "$_HOOK_CTX" | jq -Rsc --arg hook_event_name "$hook_event_name" '{
          hookSpecificOutput: {
            hookEventName: $hook_event_name,
            additionalContext: .
          }
        }'
      else
        # Successful context-injection hooks are intentionally quiet. Codex
        # still receives additionalContext, but the transcript does not get a
        # repetitive "hook context" status block after every prompt.
        _hook_agent_name _finish_agent_name
        if [ "$_finish_agent_name" = "codex" ] && _hook_codex_supports_suppress_output "$hook_event_name"; then
          printf '%s' "$_HOOK_CTX" | jq -Rsc --arg hook_event_name "$hook_event_name" '{
            suppressOutput: true,
            hookSpecificOutput: {
              hookEventName: $hook_event_name,
              additionalContext: .
            }
          }'
        else
          printf '%s' "$_HOOK_CTX" | jq -Rsc --arg hook_event_name "$hook_event_name" '{
            hookSpecificOutput: {
              hookEventName: $hook_event_name,
              additionalContext: .
            }
          }'
        fi
      fi
    else
      local hook_event_name
      _hook_event_name hook_event_name
      printf '%s' "$_HOOK_CTX" | jq -Rsc --arg hook_event_name "$hook_event_name" '{
        context: .,
        hookSpecificOutput: { hookEventName: $hook_event_name, additionalContext: . }
      }'
    fi
  else
    printf '{}\n'
  fi
  # Status of the branch's last command: the jq (or printf) that wrote stdout.
  local emit_status=$?
  if [ -n "$_HOOK_BLOCKED" ] || [ "$emit_status" -ne 0 ]; then
    _hook_hm_undelivered
  fi
  [ -n "$_HOOK_BLOCKED" ] && exit 2
  exit 0
}

# Only executables named agent-hook-* install the exit trap (top of this file):
# non-hook launchers (agentguard-churn-bypass) and test harnesses also source
# this library, and their exits are not hook events. Extensions run inside the
# hook process and share its single record. Parsed-command and edit-file
# variables are exported for extensions, so a hook can inherit them from a
# parent hook's children (a nested agent). Clear them here: every hook parses
# its own before use, and a record must never attribute a parent's command to
# this hook.
case "${_HOOK_SELF:-$0}" in
  agent-hook-* | */agent-hook-*)
    unset AGENTGUARD_CMD_TRIMMED AGENTGUARD_CMD_LINE1 AGENTGUARD_EDIT_FILES AGENTGUARD_EDIT_FILE
    ;;
esac
