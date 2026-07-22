#!/usr/bin/env bash
# hook-helpers.sh — shared helpers for AI agent hook scripts.
# Source at the top of every hook. Provides accumulators for blocks,
# warnings, and context, plus work-variant sourcing and final emission.
# Agent-agnostic: works with Claude Code, Codex, Gemini CLI, or any
# agent that follows the same hook protocol (JSON on stdout, exit 2
# to block).
#
# Every base hook follows the same lifecycle:
#   source helpers → base logic → _hook_source_extensions → _hook_finish
# Order is most-general to most-specific: base (universal) → agent
# (Claude/Codex/Gemini specific) → work (environment specific) → emit + exit.

# --- State (computed once at source time, no subshells) ---

_HOOK_BLOCKED=''
_HOOK_CTX=''
_HOOK_STOP_CONTINUE=''
_HOOK_HM_CONFIG_PATH=''

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
    claude | gemini) return 1 ;;
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
# a victim's tree (CWE-377/CWE-59). Prefer XDG_RUNTIME_DIR: a per-user 0700
# directory the system wipes on logout, which is the canonical home for
# ephemeral runtime state and keeps stale per-session dirs from accumulating.
# Fall back to XDG_STATE_HOME, then ~/.local/state, and only to a uid-scoped tmp
# path when neither a runtime dir nor HOME is available, so hooks never
# hard-fail.
_hook_state_root() {
  local base="${XDG_RUNTIME_DIR:-}"
  [ -n "$base" ] || base="${XDG_STATE_HOME:-}"
  [ -n "$base" ] || { [ -n "${HOME:-}" ] && base="$HOME/.local/state"; }
  if [ -n "$base" ]; then
    printf '%s/agentguard/hook-state' "$base"
  else
    printf '%s/agentguard-hook-state-%s' "${TMPDIR:-/tmp}" "$(id -u 2>/dev/null || echo 0)"
  fi
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

# Session key for state directory isolation. Prefer stable runtime ids. Codex
# hook commands can inherit CODEX_THREAD_ID from an outer Codex process when a
# user launches nested Codex, so once Codex JSON has been read its session_id is
# the authoritative key. If Codex does not expose one, managed hooks fall back
# to the long-lived Codex parent process instead of each short-lived hook
# process. Gemini also lacks a durable id, so its parent CLI process remains
# the key. Other hook runners may only provide a JSON session_id on stdin;
# parsers refresh after reading it. Empty or session-less JSON must still fall
# through to the Codex process key; otherwise reading a closed stdin would
# downgrade an already-stable session to this one hook process.
_hook_refresh_state_dir() {
  local session_key='' input_session='' codex_key=''
  if [ -n "${_HOOK_INPUT+x}" ]; then
    input_session=$(printf '%s' "$_HOOK_INPUT" | jq -r '.session_id // empty' 2>/dev/null)
  fi

  if [ "${AGENTGUARD_NAME:-}" = "codex" ] && [ -n "$input_session" ]; then
    session_key="$input_session"
  elif [ -n "${AGENTGUARD_SESSION_ID:-}" ]; then
    session_key="$AGENTGUARD_SESSION_ID"
  elif [ -n "${CODEX_THREAD_ID:-}" ]; then
    session_key="$CODEX_THREAD_ID"
  elif [ "${AGENTGUARD_NAME:-}" != "codex" ] && [ -n "${CLAUDE_CODE_CURRENT_SESSION_ID:-}" ]; then
    session_key="$CLAUDE_CODE_CURRENT_SESSION_ID"
  elif [ -n "$input_session" ]; then
    session_key="$input_session"
  fi

  if [ -z "$session_key" ] && codex_key=$(_hook_codex_process_key); then
    session_key="$codex_key"
  elif [ -z "$session_key" ] && [ -n "${GEMINI_PROJECT_DIR:-}" ]; then
    session_key="gemini-$PPID"
  fi

  [ -n "$session_key" ] || session_key="$$"
  _HOOK_SESSION_KEY="$session_key"
  _HOOK_STATE_DIR="$(_hook_state_root)/$_HOOK_SESSION_KEY"
}

_hook_refresh_state_dir

# --- Accumulators (stderr-only, never touch stdout) ---

_hook_block() {
  _HOOK_BLOCKED=1
  printf 'BLOCKED: %s\n' "$1" >&2
}

_hook_warn() {
  local message="$1"
  printf 'WARNING: %s\n' "$message" >&2
  # Successful hook stderr is not a reliable model-visible channel across
  # agents. Warnings are behavioral steer, so carry them through the protocol
  # context too while preserving stderr for logs and human debugging.
  _hook_context "$message"
}

_hook_remind() {
  local message="$1"
  printf 'REMINDER: %s\n' "$message" >&2
  _HOOK_STOP_CONTINUE=1
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
  # behavioral steer.
  _hook_mkstate "$dir" || return 0
  : >"$marker" 2>/dev/null || true
  return 0
}

_hook_once_per_prompt() {
  _hook_mark_once "$_HOOK_STATE_DIR/prompt-cycle" "$1"
}

_hook_once_per_session() {
  _hook_mark_once "$_HOOK_STATE_DIR" "$1"
}

_hook_flag_enabled() {
  case "${1:-}" in
    1 | true | TRUE | yes | YES | on | ON) return 0 ;;
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
    _hook_refresh_state_dir
    return 0
  fi
  [ ! -t 0 ] || return 1
  local input stdin_timeout
  stdin_timeout="${AGENTGUARD_HOOK_STDIN_TIMEOUT:-0.05}"
  # Some hook runners attach a non-tty stdin pipe before they have any payload
  # to send. A plain `cat` waits for EOF and can consume the runner's whole hook
  # timeout, so read at most the bytes that arrive promptly.
  if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ] && [[ "$stdin_timeout" == *.* ]] &&
    command -v perl >/dev/null 2>&1; then
    input=$(
      perl -e '
        use strict;
        use warnings;
        use IO::Select;

        my $timeout = shift @ARGV;
        my $select = IO::Select->new(*STDIN);
        my $input = "";
        if ($select->can_read($timeout)) {
          while ($select->can_read(0)) {
            my $chunk = "";
            my $read = sysread(STDIN, $chunk, 65536);
            last if !defined($read) || $read == 0;
            $input .= $chunk;
          }
        }
        print $input;
      ' "$stdin_timeout"
    )
  elif [ "${BASH_VERSINFO[0]:-0}" -lt 4 ] && [[ "$stdin_timeout" == *.* ]]; then
    # Bash 3, still shipped as /bin/bash on macOS, rejects fractional timeouts.
    # Without Perl's `select`, fall back to an integer timeout only if bytes
    # are already ready so open-empty pipes still return promptly.
    IFS= read -r -t 0 -d '' input || return 1
    IFS= read -r -t 1 -d '' input || true
  else
    IFS= read -r -t "$stdin_timeout" -d '' input || true
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
  # session instead of falling back to this one hook process id.
  _hook_refresh_state_dir
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
  local _can_block=0
  [ "$(_hook_event_name)" = "PreToolUse" ] && _can_block=1
  if ! command -v jq >/dev/null 2>&1; then
    if [ "$_can_block" = 1 ]; then
      _hook_block 'cannot inspect the command: jq is not on PATH. Install jq; refusing to run the tool call unguarded.'
      _hook_finish
    fi
    exit 0
  fi
  if ! printf '%s' "$_HOOK_INPUT" | jq empty >/dev/null 2>&1; then
    if [ "$_can_block" = 1 ]; then
      _hook_block 'cannot inspect the command: the tool payload is not valid JSON. Refusing to run it unguarded.'
      _hook_finish
    fi
    exit 0
  fi
  local cmd
  cmd=$(printf '%s' "$_HOOK_INPUT" | jq -r '.tool_input.command // .tool_input.cmd // empty' 2>/dev/null)
  # Valid JSON but no command field: there is nothing to run, so nothing to guard.
  [ -z "$cmd" ] && exit 0
  AGENTGUARD_CMD_TRIMMED=$(printf '%s' "$cmd" | sed 's/^[[:space:]]*//')
  # First line only — heredoc bodies (commit messages, etc.) start on
  # line 2 and must not trigger command-detection guards.
  AGENTGUARD_CMD_LINE1=$(printf '%s' "$AGENTGUARD_CMD_TRIMMED" | head -1)
  export AGENTGUARD_CMD_TRIMMED AGENTGUARD_CMD_LINE1
}

# Extracts shell stdout from PostToolUse-style payloads. Claude Code uses
# tool_response.stdout; other hook runners have used adjacent result/output
# object names, so keep the base post-bash scanner wired through this adapter
# instead of reading a Claude-shaped field directly.
_hook_tool_stdout() {
  _hook_read_input || return 0
  printf '%s' "$_HOOK_INPUT" | jq -r '
    def text_value(v):
      if (v | type) == "string" then v else empty end;
    [
      text_value(.tool_response.stdout?),
      text_value(.tool_result.stdout?),
      text_value(.tool_output.stdout?),
      text_value(.response.stdout?),
      text_value(.result.stdout?),
      text_value(.stdout?)
    ] | map(select(. != "")) | .[0] // empty
  ' 2>/dev/null
}

# Parses edited file paths from hook JSON input. Edit/Write style tools pass a
# single file_path; Codex API apply_patch passes a patch body, so extract the
# file headers from that structured patch format.
_hook_parse_edit_files() {
  if ! _hook_read_input; then
    AGENTGUARD_EDIT_FILES=''
    AGENTGUARD_EDIT_FILE=''
    export AGENTGUARD_EDIT_FILES AGENTGUARD_EDIT_FILE
    return 0
  fi
  AGENTGUARD_EDIT_FILES=$(printf '%s' "$_HOOK_INPUT" | jq -r '
    def patch_text:
      if (.tool_input | type) == "string" then .tool_input
      elif (.tool_input | type) == "object" then
        (.tool_input.patch // .tool_input.input // .tool_input.diff // empty)
      else empty end;
    def first_seen:
      reduce .[] as $item ([]; if index($item) then . else . + [$item] end);
    [
      (.tool_input.file_path? // empty),
      (.tool_input.path? // empty),
      (patch_text | strings | split("\n")[] |
        select(test("^\\*\\*\\* (Update|Add|Delete) File: |^\\*\\*\\* Move to: ")) |
        sub("^\\*\\*\\* (Update|Add|Delete) File: "; "") |
        sub("^\\*\\*\\* Move to: "; ""))
    ] | map(select(. != "")) | first_seen[]
  ' 2>/dev/null)
  AGENTGUARD_EDIT_FILE=$(printf '%s\n' "$AGENTGUARD_EDIT_FILES" | sed -n '1p')
  export AGENTGUARD_EDIT_FILES AGENTGUARD_EDIT_FILE
}

# Parses MCP tool info from hook JSON input. Sets _HOOK_INPUT (full JSON for
# downstream field extraction), _HOOK_MCP_SERVER, _HOOK_MCP_TOOL_NAME, and
# _HOOK_MCP_FAIL_FILE. Exits early if the tool name or server can't be
# extracted.
_hook_parse_mcp() {
  _hook_read_input || exit 0
  local tool_name remainder
  tool_name=$(printf '%s' "$_HOOK_INPUT" | jq -r '.tool_name // empty')
  [ -z "$tool_name" ] && exit 0
  case "$tool_name" in
    mcp__*__*) ;;
    *) exit 0 ;;
  esac

  remainder="${tool_name#mcp__}"
  _HOOK_MCP_SERVER="${remainder%__*}"
  [ -z "$_HOOK_MCP_SERVER" ] && exit 0
  _HOOK_MCP_TOOL_NAME="${remainder##*__}"
  [ -z "$_HOOK_MCP_TOOL_NAME" ] && exit 0

  _HOOK_MCP_TOOL="$tool_name"
  _HOOK_MCP_FAIL_FILE="$_HOOK_STATE_DIR/mcp-failures-$_HOOK_MCP_SERVER"
}

# Uses the command classifier to change into a leading `cd` target. Used by
# pre-bash and post-bash local `-work` variants to resolve repo context when
# the agent's command starts with cd. No-op if the first top-level command
# fragment is not cd or the directory doesn't exist.
_hook_cd_to_target() {
  local fragment="" fragments target_dir

  if [ "$(type -t _hook_command_fragments)" != "function" ]; then
    # shellcheck source=hook-command-classifier.sh
    # shellcheck disable=SC1091 # sibling module resolved from this file's dir.
    source "$_AGENTGUARD_LIB_DIR/hook-command-classifier.sh" || return 0
  fi

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
        .cwd?,
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
    .prompt // .user_prompt // .message // .input // .tool_input.prompt // empty
  ' 2>/dev/null
}

_hook_hm_tool_status() {
  _hook_hm_read_input
  local status
  status=$(printf '%s' "${_HOOK_INPUT:-}" | jq -r '
    def status_code(v):
      if v == null then empty
      elif (v | type) == "number" then v
      elif (v | type) == "string" then
        (v | ascii_downcase) as $s |
        if ($s | test("^[0-9]+$")) then ($s | tonumber)
        elif (["success", "succeeded", "ok", "pass", "passed"] | index($s)) then 0
        elif (["failure", "failed", "error", "errored", "fail"] | index($s)) then 1
        else empty end
      elif (v | type) == "boolean" then
        if v then 1 else 0 end
      else empty end;
    .tool_response.exit_code
    // .tool_response.status
    // .tool_result.exit_code
    // .tool_result.status
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

  if command -v timeout >/dev/null 2>&1; then
    timeout_help=$(timeout --help 2>&1 || true)
    if [[ "$timeout_help" == *BusyBox* ]]; then
      _HOOK_TIMEOUT_PREFIX=(bash -c "$_HOOK_PORTABLE_TIMEOUT_SCRIPT" _ "$seconds")
    else
      _HOOK_TIMEOUT_PREFIX=(timeout "$seconds")
    fi
  elif command -v gtimeout >/dev/null 2>&1; then
    _HOOK_TIMEOUT_PREFIX=(gtimeout "$seconds")
  else
    _HOOK_TIMEOUT_PREFIX=(bash -c "$_HOOK_PORTABLE_TIMEOUT_SCRIPT" _ "$seconds")
  fi
}

_hook_hm_event() {
  _hook_hm_available || return 0

  local event="$1"
  shift
  local project="" response err rc project_infer=1
  local -a hm_args
  _hook_hm_read_input
  err=$(mktemp "${TMPDIR:-/tmp}/hm-hook.XXXXXX") || return 0

  # Keep hook scripts policy-light: they pass event facts, and `hm` resolves
  # agent identity, project/store affinity, context freshness, and refresh
  # coalescing from config and hook state.
  hm_args=(hook "$event")
  case "$event" in
    stop | tool-complete)
      # Intentionally omit project context for these high-frequency events.
      # `session-start` and `prompt-submit` are the project-aware context
      # boundaries; `tool-complete` only reports status, and passing a project
      # hint here forces `hm` through VCS discovery after every tool call.
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

  if [ "$project_infer" -eq 0 ]; then
    response=$(
      env -u HIVE_MEMORY_PROJECT \
        HIVE_MEMORY_CONFIG="$_HOOK_HM_CONFIG_PATH" \
        HIVE_MEMORY_AGENT_ID="$(_hook_agent_name)" \
        HIVE_MEMORY_SESSION_ID="$_HOOK_SESSION_KEY" \
        HIVE_MEMORY_PROJECT_INFER=0 \
        HIVE_MEMORY_HOOK_ACTIVE=1 \
        "${_HOOK_TIMEOUT_PREFIX[@]}" hm "${hm_args[@]}" 2>"$err"
    )
  else
    response=$(
      HIVE_MEMORY_CONFIG="$_HOOK_HM_CONFIG_PATH" \
        HIVE_MEMORY_AGENT_ID="$(_hook_agent_name)" \
        HIVE_MEMORY_SESSION_ID="$_HOOK_SESSION_KEY" \
        HIVE_MEMORY_PROJECT="$project" \
        HIVE_MEMORY_PROJECT_INFER="$project_infer" \
        HIVE_MEMORY_HOOK_ACTIVE=1 \
        "${_HOOK_TIMEOUT_PREFIX[@]}" hm "${hm_args[@]}" 2>"$err"
    )
  fi
  rc=$?
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

  _hook_hm_apply_response "$response"
}

_hook_hm_session_start() {
  local marker before
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
  [ ! -e "$marker" ] || return 0

  before="$_HOOK_CTX"
  _hook_hm_event session-start
  if [ "$_HOOK_CTX" != "$before" ]; then
    # _hook_hm_event also reads stdin for callers that did not already do so,
    # so derive the marker path from the post-event state as a final guard.
    marker="$_HOOK_STATE_DIR/hm-session-start-context-emitted"
    _hook_mkstate "$_HOOK_STATE_DIR" || return 0
    : >"$marker" 2>/dev/null || true
  fi
}

_hook_hm_prompt_submit() {
  local prompt
  # Read stdin in this shell before extracting the prompt. Command substitution
  # runs helper calls in a subshell, so letting `_hook_hm_prompt_text` perform
  # the first read would consume hook JSON without preserving `_HOOK_INPUT` for
  # agent-specific and local extensions sourced later in this hook.
  _hook_hm_read_input
  prompt=$(_hook_hm_prompt_text)
  [ -n "$prompt" ] || return 0
  _hook_hm_event prompt-submit --text "$prompt"
}

_hook_hm_tool_complete() {
  _hook_hm_event tool-complete --status "$(_hook_hm_tool_status)"
}

_hook_hm_stop() {
  _hook_hm_event stop
}

# --- Agent identification ---

# Returns the name of the running agent. Delegates to the shared
# `_agent_name` detection and falls back to "agent" (not "unknown")
# because in a hook context _something_ is always driving.
_hook_agent_name() {
  local name
  name=$(_agent_name)
  [ "$name" != "unknown" ] && echo "$name" || echo "agent"
}

# --- Delegation ---

# Sources the agent-specific extension (-claude, -codex, or -gemini)
# based on which agent is running. Auto-discovers by appending the
# agent name to the hook's own filename (e.g., hook-pre-bash-gemini).
_hook_source_agent() {
  local agent_file
  agent_file="${_HOOK_SELF:-$0}-$(_hook_agent_name)"
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

_hook_event_name() {
  local hook_name
  hook_name=$(basename "${_HOOK_SELF:-$0}")
  case "$hook_name" in
    agent-hook-session-start*) echo "SessionStart" ;;
    agent-hook-prompt-submit*) echo "UserPromptSubmit" ;;
    agent-hook-pre-*) echo "PreToolUse" ;;
    agent-hook-post-*) echo "PostToolUse" ;;
    agent-hook-stop*) echo "Stop" ;;
    agent-hook-notification*) echo "PermissionRequest" ;;
    *) echo "UserPromptSubmit" ;;
  esac
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
  # Codex Stop has its own strict schema and does not accept the
  # hookSpecificOutput/additionalContext envelope used by other context hooks.
  # Only explicit reminders or blocks should continue the turn. Warnings are
  # useful context on prompt/tool hooks, but a best-effort warning during Stop
  # should not trap the agent in a shutdown loop.
  if [ -n "$_HOOK_STOP_CONTINUE" ] || [ -n "$_HOOK_BLOCKED" ]; then
    printf '%s' "$_HOOK_CTX" | jq -Rsc '{
      decision: "block",
      reason: .
    }'
  else
    printf '{}\n'
  fi
}

# Emits one JSON response and exits. Must be the last call in every hook.
# Emits legacy "context" for Claude plus Gemini-compatible additionalContext.
# Codex uses strict per-event hookSpecificOutput schemas with no legacy fields.
_hook_finish() {
  if [ -n "$_HOOK_CTX" ]; then
    if [ "$(_hook_agent_name)" = "codex" ]; then
      local hook_event_name
      hook_event_name=$(_hook_event_name)
      if [ "$hook_event_name" = "Stop" ]; then
        _hook_finish_codex_stop
        exit 0
      fi
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
        if _hook_codex_supports_suppress_output "$hook_event_name"; then
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
      hook_event_name=$(_hook_event_name)
      printf '%s' "$_HOOK_CTX" | jq -Rsc --arg hook_event_name "$hook_event_name" '{
        context: .,
        hookSpecificOutput: { hookEventName: $hook_event_name, additionalContext: . }
      }'
    fi
  else
    printf '{}\n'
  fi
  [ -n "$_HOOK_BLOCKED" ] && exit 2
  exit 0
}
