# shellcheck shell=bash
# telemetry.sh — durable per-session audit records for AgentGuard hooks.
#
# Storage contract (schema `agentguard.telemetry.v1`, documented in
# docs/telemetry.md):
#
#   <root>/sessions/<agent>/<session-key>/<epoch-us>-<pid>-<hook>.json
#
# Each file holds exactly one compact JSON record. One file per hook
# invocation (rather than one shared JSONL log) is deliberate: hosts run
# matching hooks in parallel, and a large record (a PostToolUse payload with
# full command output) can be split across several write(2) calls, so
# concurrent appends to one log could interleave. Writing a private temp file
# and renaming it into place is atomic on every supported platform and needs no
# lock. Filenames start with a fixed-width microsecond timestamp, so a plain
# lexical glob is chronological and `cat <session>/*.json` is valid JSONL.
#
# The root is durable user state, not runtime state: XDG_RUNTIME_DIR is wiped
# at logout, which would destroy the audit trail. The XDG Base Directory spec
# names XDG_STATE_HOME (default ~/.local/state) as the home for "actions
# history (logs, history, ...)", which is exactly this data.
#
# This file has no dependency on hook-helpers.sh so the read-side CLI can source
# it without paying for hook session resolution. Sourcing defines functions
# only; it changes no shell options or traps.

_AGENTGUARD_TELEMETRY_SCHEMA='agentguard.telemetry.v1'

# Whether telemetry recording is enabled. Opt-out rather than opt-in: the
# audit trail is only useful if it already exists when someone needs it.
_agentguard_telemetry_enabled() {
  case "${AGENTGUARD_TELEMETRY:-1}" in
    0 | false | FALSE | no | NO | off | OFF) return 1 ;;
    *) return 0 ;;
  esac
}

# Primary telemetry root. Only absolute overrides are honored: hook processes
# run from arbitrary working directories, so a relative path would scatter one
# session's records across projects.
_agentguard_telemetry_root() {
  case "${AGENTGUARD_TELEMETRY_DIR:-}" in
    /*)
      printf '%s\n' "${AGENTGUARD_TELEMETRY_DIR%/}"
      return 0
      ;;
  esac
  case "${XDG_STATE_HOME:-}" in
    /*)
      printf '%s/agentguard/telemetry\n' "${XDG_STATE_HOME%/}"
      return 0
      ;;
  esac
  [ -n "${HOME:-}" ] || return 1
  printf '%s/.local/state/agentguard/telemetry\n' "$HOME"
}

# Every root a reader should search, primary first, without duplicates. Some
# runtimes scrub XDG_* from hook environments while an interactive shell keeps
# it, so hooks and the CLI can disagree about the primary root; readers merge
# the plausible tiers instead of silently missing sessions.
_agentguard_telemetry_roots() {
  local candidate seen=''
  for candidate in \
    "$(_agentguard_telemetry_root 2>/dev/null)" \
    "${XDG_STATE_HOME:+${XDG_STATE_HOME%/}/agentguard/telemetry}" \
    "${HOME:+$HOME/.local/state/agentguard/telemetry}"; do
    case "$candidate" in
      /*) ;;
      *) continue ;;
    esac
    case "
$seen
" in
      *"
$candidate
"*) continue ;;
    esac
    seen="$seen
$candidate"
    printf '%s\n' "$candidate"
  done
}

# Store the current time in microseconds since the epoch into the variable
# named by $1. Bash 5's EPOCHREALTIME needs no fork, which matters because
# every hook calls this twice; its decimal separator follows LC_NUMERIC, hence
# the `[.,]`. Older shells fall back to whole seconds, which keeps filenames
# fixed-width and sortable at reduced resolution.
_agentguard_telemetry_now_us() {
  local now="${EPOCHREALTIME:-}" seconds
  if [[ "$now" =~ ^([0-9]+)[.,]([0-9]{6})$ ]]; then
    printf -v "$1" '%s%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    return 0
  fi
  seconds=$(date +%s 2>/dev/null) || seconds=0
  printf -v "$1" '%s000000' "$seconds"
}

# Retention window in days; 0 keeps records forever. Invalid values fall back
# to the default rather than disabling pruning by accident.
_agentguard_telemetry_retention_days() {
  local days="${AGENTGUARD_TELEMETRY_RETENTION_DAYS:-90}"
  case "$days" in
    '' | *[!0-9]*) days=90 ;;
  esac
  printf '%s\n' "$days"
}

# Delete session directories whose last activity is older than $2 days under
# root $1. A session directory's mtime advances whenever a record is renamed
# into it, so it tracks the session's most recent hook rather than its start.
_agentguard_telemetry_prune() {
  local root="$1" days="$2"
  case "$root" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$days" in
    '' | *[!0-9]*) return 1 ;;
  esac
  [ "$days" -gt 0 ] || return 0
  [ -d "$root/sessions" ] || return 0
  find "$root/sessions" -mindepth 2 -maxdepth 2 -type d -mtime "+$days" \
    -exec rm -rf {} + 2>/dev/null
  # Drop agent directories emptied by the pass; rmdir refuses non-empty ones.
  find "$root/sessions" -mindepth 1 -maxdepth 1 -type d -empty \
    -exec rmdir {} + 2>/dev/null
  return 0
}
