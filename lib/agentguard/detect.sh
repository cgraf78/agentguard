#!/usr/bin/env bash
# detect.sh — detect whether an AI agent session is driving.
#
# Lightweight and self-contained so VCS hooks, agent hooks, and scripts
# can source it without pulling in the full hook infrastructure.
#
# Detection relies primarily on environment variables each agent runtime exports
# into child processes. The check order matters: Codex can coexist with
# Claude-compatible vars, and Gemini sets CLAUDE_PROJECT_DIR (but not the
# session ID), so the most-specific check must come first.
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

_agent_name_from_process_tree() {
  [ "${AGENTGUARD_PROCESS_DETECT:-1}" != "0" ] || return 1

  local pid parent comm
  pid="$$"
  while [ -n "$pid" ] && [ "$pid" != "0" ]; do
    # Match on the executable NAME only, never the argument text. An earlier
    # version scanned `ps args`, which let a command's own arguments masquerade
    # as a Codex process: any ancestor running `hm remember`, `git commit`, or
    # similar with the word "codex" in its payload was misattributed to Codex,
    # corrupting agent identity. Process identity must come from the binary
    # name, not from what the binary was asked to do.
    comm=$(ps -o comm= -p "$pid" 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//') || break
    if [ "$(basename "$comm" 2>/dev/null)" = "codex" ]; then
      echo "codex"
      return 0
    fi

    parent=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ "$parent" != "$pid" ] || break
    pid="$parent"
  done

  return 1
}

# Returns 0 when an AI agent session is detected, 1 otherwise.
_is_agent_session() {
  [ -n "${AGENTGUARD_NAME:-}" ] ||
    [ -n "${AGENTGUARD_SESSION_ID:-}" ] ||
    [ -n "${CODEX_THREAD_ID:-}" ] ||
    [ "${CODEX_INTERNAL_ORIGINATOR_OVERRIDE:-}" = "codex" ] ||
    [ -n "${CLAUDE_CODE_CURRENT_SESSION_ID:-}" ] ||
    [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] ||
    [ -n "${GEMINI_PROJECT_DIR:-}" ] ||
    [ -n "$(_agent_name_from_process_tree)" ]
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
  elif [ -n "${CLAUDE_CODE_CURRENT_SESSION_ID:-}" ] || [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
    echo "claude"
  elif [ -n "${AGENTGUARD_SESSION_ID:-}" ]; then
    echo "agent"
  elif process_name=$(_agent_name_from_process_tree); then
    echo "$process_name"
  else
    echo "unknown"
  fi
}
