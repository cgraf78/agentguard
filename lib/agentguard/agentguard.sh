# shellcheck shell=bash
# agentguard.sh - public API for agent runtime detection.
#
# Source this file when a non-hook caller needs agentguard behavior without the
# full hook helper runtime:
#   . "$(shdeps dep-file cgraf78/agentguard lib/agentguard/agentguard.sh)"

_AGENTGUARD_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=detect.sh
# shellcheck disable=SC1091 # sibling module resolved from this file's dir.
. "$_AGENTGUARD_LIB_DIR/detect.sh"

# ---------------------------------------------------------------------------
# Public API - stable interface for scripts and integration harnesses
# ---------------------------------------------------------------------------
# Every public agentguard function is defined here with an agentguard_ prefix.
# Hook-only helpers live in hook-helpers.sh and keep their private _hook_
# prefix because they depend on hook runtime state.

# agentguard_is_session
#   Return 0 when the current process appears to be running under an AI agent.
agentguard_is_session() {
  _is_agent_session
}

# agentguard_agent_name
#   Print the detected agent name, or "unknown" when it cannot be identified.
agentguard_agent_name() {
  _agent_name
}

# agentguard_session_id [fallback_namespace]
#   Print the detected session id, or return 1 without output when the current
#   process is not running under a known or explicitly named agent. An optional
#   namespace identifies a caller-known context and names only generic
#   parent-process fallbacks; native and runtime-specific identities still win.
agentguard_session_id() {
  _agent_session_id "$@"
}
