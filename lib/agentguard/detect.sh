#!/usr/bin/env bash
# detect.sh — detect whether an AI agent session is driving.
#
# Lightweight and self-contained so VCS hooks, agent hooks, and scripts
# can source it without pulling in the full hook infrastructure.
#
# Detection relies primarily on environment variables each agent runtime exports
# into child processes. The check order matters: Codex can coexist with
# Claude-compatible vars, Gemini sets CLAUDE_PROJECT_DIR (but not the
# session ID), and Grok injects CLAUDE_PROJECT_DIR on hook processes as a
# compatibility alias for GROK_WORKSPACE_ROOT, so the most-specific check must
# come first.
#
# Claude Code exports CLAUDE_CODE_SESSION_ID into every tool subprocess, but
# only the hook runtime sees the CLAUDE_CODE_CURRENT_SESSION_ID variant. We must
# accept either spelling, otherwise a plain Claude tool subprocess (e.g. a
# direct `hm` invocation) fails the env check and falls through to the weaker
# process-tree heuristic below.
#
# Codex has had runtime builds that launch hooks without a Codex-specific env
# var. Keep a small process-tree fallback so already-running sessions still
# produce Codex-shaped hook JSON even before regenerated config can inject
# AGENTGUARD_NAME=codex explicitly.

_agent_match_process_snapshot() {
  local target="$1"
  local snapshot="$2"

  [ -n "$snapshot" ] || return 2
  printf '%s\n' "$snapshot" | awk -v start="$$" -v target="$target" '
    {
      pid = $1
      parent[pid] = $2
      $1 = $2 = ""
      sub(/^[[:space:]]+/, "")
      command[pid] = $0
    }
    END {
      if (!(start in command)) exit 2
      pid = start
      while (pid != "" && pid != "0" && !seen[pid]++) {
        name = command[pid]
        sub(/^.*\//, "", name)
        if (name == target) {
          print pid
          found = 1
          break
        }
        if (!(pid in parent)) {
          incomplete = 1
          break
        }
        next_pid = parent[pid]
        if (next_pid == pid) break
        if (next_pid != "" && next_pid != "0" && !(next_pid in command)) {
          incomplete = 1
          break
        }
        pid = next_pid
      }
      exit(found ? 0 : (incomplete ? 2 : 1))
    }
  '
}

# One process-table snapshot per process, shared by every detector in this
# file and by the hook ancestor resolver. A hook's parent chain is fixed once
# the hook is spawned, so ancestors cannot change mid-hook: re-running
# `ps -axo` per resolution only re-reads the same table at ~95 ms a snapshot
# on a loaded host. Callers must invoke this in the current shell (never in
# $(), whose assignment would die with the subshell) and then read
# $_AGENT_PROCESS_SNAPSHOT. A failed fetch caches as empty, and every caller
# already treats an empty snapshot as "unresolved" with its usual fallback.
_agent_process_snapshot() {
  if [ -z "${_AGENT_PROCESS_SNAPSHOT_FETCHED:-}" ]; then
    _AGENT_PROCESS_SNAPSHOT_FETCHED=1
    _AGENT_PROCESS_SNAPSHOT=$(ps -axo pid=,ppid=,comm= 2>/dev/null) || _AGENT_PROCESS_SNAPSHOT=''
  fi
  [ -n "$_AGENT_PROCESS_SNAPSHOT" ]
}

_agent_process_tree_snapshot_pid() {
  local target="$1"

  _agent_process_snapshot || return 2
  _agent_match_process_snapshot "$target" "$_AGENT_PROCESS_SNAPSHOT"
}

_agent_process_tree_walk_pid() {
  local target="$1"
  local pid parent comm

  # Fall back for minimal or older `ps` implementations without a portable
  # all-process snapshot. This path is slower but preserves detection rather
  # than turning a missing `ps -a` capability into a false human classification.
  pid="$$"
  while [ -n "$pid" ] && [ "$pid" != "0" ]; do
    # Match on the executable NAME only, never the argument text. An earlier
    # version scanned `ps args`, which let a command's own arguments masquerade
    # as a Codex process: any ancestor running `hm remember`, `git commit`, or
    # similar with the word "codex" in its payload was misattributed to Codex,
    # corrupting agent identity. Process identity must come from the binary
    # name, not from what the binary was asked to do.
    comm=$(ps -o comm= -p "$pid" 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//') || break
    if [ "$(basename "$comm" 2>/dev/null)" = "$target" ]; then
      echo "$pid"
      return 0
    fi

    parent=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ "$parent" != "$pid" ] || break
    pid="$parent"
  done

  return 1
}

_agent_process_tree_pid() {
  local target="$1"
  local snapshot_status

  _agent_process_tree_snapshot_pid "$target" && return 0
  snapshot_status=$?
  [ "$snapshot_status" -ne 2 ] && return "$snapshot_status"
  _agent_process_tree_walk_pid "$target"
}

_agent_codex_process_pid() {
  _agent_process_tree_pid codex
}

_agent_grok_process_pid() {
  # Match the grok binary only. The installer also links `agent` to the same
  # image, but `agent` is a generic process name and would misattribute
  # unrelated tools the way argv scanning once misattributed Codex.
  _agent_process_tree_pid grok
}

_agent_name_from_process_tree() {
  local snapshot snapshot_status=0 match_status target

  [ "${AGENTGUARD_PROCESS_DETECT:-1}" != "0" ] || return 1

  # One process snapshot, then Codex before Grok on that same table. A second
  # `ps` per runtime would make every human `hm` invocation pay for Grok even
  # when the tree is already a complete non-match.
  snapshot=''
  if _agent_process_snapshot; then
    snapshot="$_AGENT_PROCESS_SNAPSHOT"
  fi
  if [ -n "$snapshot" ]; then
    for target in codex grok; do
      _agent_match_process_snapshot "$target" "$snapshot" >/dev/null
      match_status=$?
      case "$match_status" in
        0)
          echo "$target"
          return 0
          ;;
        2) snapshot_status=2 ;;
      esac
    done
    [ "$snapshot_status" -ne 2 ] && return 1
  fi

  for target in codex grok; do
    if _agent_process_tree_walk_pid "$target" >/dev/null; then
      echo "$target"
      return 0
    fi
  done

  return 1
}

# Returns 0 when an AI agent session is detected, 1 otherwise.
_is_agent_session() {
  [ -n "${AGENTGUARD_NAME:-}" ] ||
    [ -n "${AGENTGUARD_SESSION_ID:-}" ] ||
    [ -n "${CODEX_THREAD_ID:-}" ] ||
    [ "${CODEX_INTERNAL_ORIGINATOR_OVERRIDE:-}" = "codex" ] ||
    [ -n "${GROK_SESSION_ID:-}" ] ||
    [ -n "${CLAUDE_CODE_CURRENT_SESSION_ID:-}" ] ||
    [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] ||
    [ -n "${GEMINI_PROJECT_DIR:-}" ] ||
    [ -n "$(_agent_name_from_process_tree)" ]
}

# Resolve a generic $AGENT export to a known runtime name. Some launchers
# identify the runtime only through $AGENT (no runtime-specific session id),
# which previously forced full process-tree detection on every hook. Only
# exact known-runtime names match (ASCII case-insensitive); anything else
# returns 1 silently so detection falls through unchanged.
_agent_name_from_generic_env() {
  case "${AGENT:-}" in
    [Cc][Ll][Aa][Uu][Dd][Ee]) echo "claude" ;;
    [Cc][Oo][Dd][Ee][Xx]) echo "codex" ;;
    [Gg][Ee][Mm][Ii][Nn][Ii]) echo "gemini" ;;
    [Gg][Rr][Oo][Kk]) echo "grok" ;;
    [Mm][Uu][Ss][Ee]) echo "muse" ;;
    *) return 1 ;;
  esac
}

# Prints the name of the detected agent, or "unknown" when detection
# cannot identify one. Callers that need a hook-context fallback (e.g.,
# SLEY_CALLER attribution) should default "unknown" to their own label.
_agent_name() {
  local process_name
  if [ -n "${AGENTGUARD_NAME:-}" ]; then
    echo "$AGENTGUARD_NAME"
  elif [ -n "${CODEX_THREAD_ID:-}" ] || [ "${CODEX_INTERNAL_ORIGINATOR_OVERRIDE:-}" = "codex" ]; then
    echo "codex"
  elif [ -n "${GEMINI_PROJECT_DIR:-}" ]; then
    echo "gemini"
  elif [ -n "${GROK_SESSION_ID:-}" ]; then
    # Grok hook subprocesses also export CLAUDE_PROJECT_DIR as an alias for
    # GROK_WORKSPACE_ROOT. Identify Grok by its own session id before Claude
    # session vars so a future Claude-compat export cannot relabel the runtime.
    echo "grok"
  elif [ -n "${CLAUDE_CODE_CURRENT_SESSION_ID:-}" ] || [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
    echo "claude"
  elif _agent_name_from_generic_env; then
    # The helper already printed the resolved name; nothing left to do.
    :
  elif [ -n "${AGENTGUARD_SESSION_ID:-}" ]; then
    echo "agent"
  elif process_name=$(_agent_name_from_process_tree); then
    echo "$process_name"
  else
    echo "unknown"
  fi
}

# Print the best available session identity for a detected agent. This is the
# non-hook counterpart to the JSON-aware session state in hook-helpers.sh:
# direct child processes have no hook payload to consult, so they use stable
# runtime environment ids where available and the long-lived parent otherwise.
#
# Keep this inference next to _agent_name so sourceable consumers cannot drift
# into subtly different precedence rules. In particular, AGENTGUARD_NAME is an
# explicit runtime selection: when it is present, inherited variables from an
# outer or compatible agent must not silently change the synthetic identity.
#
# An optional caller namespace applies only to the generic parent fallback. It
# lets an adapter retain its own public identity without duplicating this
# precedence matrix. Native ids and runtime-specific fallbacks deliberately
# ignore it so relabeling a Codex, Claude, Gemini, or Grok call cannot split
# one runtime session into unrelated identities. Return 1 without output for
# an ordinary human shell when the caller supplies no namespace.
_agent_session_id() {
  local fallback_namespace="${1:-}" name

  if [ -n "${AGENTGUARD_SESSION_ID:-}" ]; then
    printf '%s\n' "$AGENTGUARD_SESSION_ID"
    return 0
  fi

  name=$(_agent_name)
  case "$name" in
    unknown)
      if [ -n "$fallback_namespace" ]; then
        printf '%s-%s\n' "$fallback_namespace" "$PPID"
      else
        return 1
      fi
      ;;
    codex)
      printf '%s\n' "${CODEX_THREAD_ID:-codex-$PPID}"
      ;;
    claude)
      printf '%s\n' \
        "${CLAUDE_CODE_CURRENT_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-claude-$PPID}}"
      ;;
    gemini)
      # Gemini does not currently expose a durable session id to ordinary
      # subprocesses. Its parent CLI remains stable for the direct-call
      # lifetime, matching AgentGuard's hook fallback.
      printf 'gemini-%s\n' "$PPID"
      ;;
    grok)
      printf '%s\n' "${GROK_SESSION_ID:-grok-$PPID}"
      ;;
    *)
      # Compatible runtimes can opt in with AGENTGUARD_NAME even before they
      # have a native stable-id variable. Namespacing the parent avoids cross-
      # runtime collisions while keeping repeated direct calls correlated.
      printf '%s-%s\n' "${fallback_namespace:-$name}" "$PPID"
      ;;
  esac
}
