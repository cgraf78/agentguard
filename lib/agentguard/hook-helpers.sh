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

# General non-interactive shells get env.d through BASH_ENV/.zshenv. This is a
# hook-local fallback for launchers that invoke hook scripts by absolute path
# with a sparse environment. Do this before the first external command below:
# empty PATH would otherwise make `dirname` unavailable, and a trailing `:`
# would add the current directory to command lookup.
if [ -n "${PATH:-}" ]; then
  case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) [ -d "$HOME/.local/bin" ] && PATH="$HOME/.local/bin:$PATH" ;;
  esac
else
  PATH="/usr/local/bin:/usr/bin:/bin"
  [ -d "$HOME/.local/bin" ] && PATH="$HOME/.local/bin:$PATH"
fi
export PATH

_AGENTGUARD_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

  local pid parent comm args saw_codex=''
  pid="$$"
  while [ -n "$pid" ] && [ "$pid" != "0" ]; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//') || break
    args=$(ps -o args= -p "$pid" 2>/dev/null || true)
    case "$(basename "$comm" 2>/dev/null) $args" in
      codex\ * | *"/codex "* | *"/codex" | *" codex "*)
        saw_codex="$pid"
        ;;
    esac

    parent=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ "$parent" != "$pid" ] || break
    pid="$parent"
  done

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

# Session key for state directory isolation. Prefer stable runtime ids. Codex
# does not consistently expose one to hooks, so managed Codex hooks fall back to
# the long-lived Codex parent process instead of each short-lived hook process.
# Gemini also lacks a durable id, so its parent CLI process remains the key.
# Other hook runners may only provide a JSON session_id on stdin; parsers
# refresh after reading it. Empty or session-less JSON must still fall through to
# the Codex process key; otherwise reading a closed stdin would downgrade an
# already-stable session to this one hook process.
_hook_refresh_state_dir() {
  local session_key='' input_session='' codex_key=''
  if [ -n "${AGENTGUARD_SESSION_ID:-}" ]; then
    session_key="$AGENTGUARD_SESSION_ID"
  elif [ -n "${CODEX_THREAD_ID:-}" ]; then
    session_key="$CODEX_THREAD_ID"
  elif [ "${AGENTGUARD_NAME:-}" != "codex" ] && [ -n "${CLAUDE_CODE_CURRENT_SESSION_ID:-}" ]; then
    session_key="$CLAUDE_CODE_CURRENT_SESSION_ID"
  elif [ -n "${_HOOK_INPUT+x}" ]; then
    input_session=$(printf '%s' "$_HOOK_INPUT" | jq -r '.session_id // empty' 2>/dev/null)
    [ -n "$input_session" ] && session_key="$input_session"
  fi

  if [ -z "$session_key" ] && codex_key=$(_hook_codex_process_key); then
    session_key="$codex_key"
  elif [ -z "$session_key" ] && [ -n "${GEMINI_PROJECT_DIR:-}" ]; then
    session_key="gemini-$PPID"
  fi

  [ -n "$session_key" ] || session_key="$$"
  _HOOK_SESSION_KEY="$session_key"
  _HOOK_STATE_DIR="${TMPDIR:-/tmp}/hook-state/$_HOOK_SESSION_KEY"
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
  # Same rationale as _hook_warn: reminders should affect the next model turn,
  # not depend on whether a client happens to surface successful-hook stderr.
  _hook_context "$message"
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

# Parses the shell command from hook JSON input. Caches the full JSON in
# _HOOK_INPUT (same contract as _hook_parse_mcp) so agent-specific and local
# extensions can read additional fields. Sets CMD_TRIMMED (full command,
# exported for local `-work` variants) and CMD_LINE1 (first line only, for
# command-detection guards that must ignore heredoc bodies). Exits early if no
# command.
_hook_parse_command() {
  [ -z "${_HOOK_INPUT+x}" ] && _HOOK_INPUT=$(cat)
  _hook_refresh_state_dir
  local cmd
  cmd=$(printf '%s' "$_HOOK_INPUT" | jq -r '.tool_input.command // .tool_input.cmd // empty')
  [ -z "$cmd" ] && exit 0
  CMD_TRIMMED=$(printf '%s' "$cmd" | sed 's/^[[:space:]]*//')
  # First line only — heredoc bodies (commit messages, etc.) start on
  # line 2 and must not trigger command-detection guards.
  CMD_LINE1=$(printf '%s' "$CMD_TRIMMED" | head -1)
  export CMD_TRIMMED CMD_LINE1
}

# Extracts shell stdout from PostToolUse-style payloads. Claude Code uses
# tool_response.stdout; other hook runners have used adjacent result/output
# object names, so keep the base post-bash scanner wired through this adapter
# instead of reading a Claude-shaped field directly.
_hook_tool_stdout() {
  [ -z "${_HOOK_INPUT+x}" ] && _HOOK_INPUT=$(cat)
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
  [ -z "${_HOOK_INPUT+x}" ] && _HOOK_INPUT=$(cat)
  _hook_refresh_state_dir
  HOOK_EDIT_FILES=$(printf '%s' "$_HOOK_INPUT" | jq -r '
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
  FP=$(printf '%s\n' "$HOOK_EDIT_FILES" | sed -n '1p')
  export HOOK_EDIT_FILES FP
}

# Parses MCP tool info from hook JSON input. Sets _HOOK_INPUT (full JSON
# for downstream field extraction), _HOOK_MCP_SERVER, and _HOOK_MCP_FAIL_FILE.
# Exits early if the tool name or server can't be extracted.
_hook_parse_mcp() {
  _HOOK_INPUT=$(cat)
  _hook_refresh_state_dir
  local tool_name
  tool_name=$(printf '%s' "$_HOOK_INPUT" | jq -r '.tool_name // empty')
  [ -z "$tool_name" ] && exit 0

  # Extract server name: mcp__my_server__some_tool → my_server
  _HOOK_MCP_SERVER=$(printf '%s' "$tool_name" | sed 's/^mcp__//; s/__[^_].*$//')
  [ -z "$_HOOK_MCP_SERVER" ] && exit 0

  _HOOK_MCP_TOOL="$tool_name"
  _HOOK_MCP_FAIL_FILE="$_HOOK_STATE_DIR/mcp-failures-$_HOOK_MCP_SERVER"
}

# Parses a cd target from CMD_TRIMMED and changes to it. Used by
# pre-bash and post-bash local `-work` variants to resolve repo context when
# the agent's command starts with cd. No-op if the command doesn't
# start with cd or the directory doesn't exist.
_hook_cd_to_target() {
  local target_dir
  target_dir=$(printf '%s' "$CMD_LINE1" | sed -n 's/^cd[[:space:]]\{1,\}\([^[:space:];&]\{1,\}\).*/\1/p')
  [ -z "$target_dir" ] && return
  target_dir="${target_dir/#\~/$HOME}"
  [ -d "$target_dir" ] && cd "$target_dir" || return 0
}

# --- Hive Memory integration ---

_hook_hm_available() {
  # Tests and emergency debugging can disable Hive Memory without changing the
  # installed hook config. Production defaults to enabled so memory context is
  # automatic once `hm` and its config are present.
  [ "${HIVE_MEMORY_HOOKS:-1}" != "0" ] || return 1
  # `hm hook` may run lower-level `hm` maintenance commands. If those commands
  # themselves trigger agent hooks, skip here so a refresh/render cycle cannot
  # recursively call back into Hive Memory.
  [ "${HIVE_MEMORY_HOOK_ACTIVE:-0}" != "1" ] || return 1
  command -v hm >/dev/null 2>&1 || return 1
  [ -f "$HOME/.config/hive-memory/config.toml" ] || return 1
}

_hook_hm_read_input() {
  [ -n "${_HOOK_INPUT+x}" ] && return 0
  [ ! -t 0 ] || return 0
  local input
  input=$(cat)
  # Non-interactive test shells and some hook launchers can present an already
  # closed stdin. Treat that as "no hook JSON" instead of caching an empty input:
  # an empty _HOOK_INPUT would make the state refresh look for a missing
  # session_id and could downgrade a stable Codex process key to this short-lived
  # hook process.
  [ -n "$input" ] || return 0
  _HOOK_INPUT="$input"
  # Some hook runners provide the durable session id only in JSON stdin. Refresh
  # after Hive Memory reads that payload so memory-pending state is session-wide
  # instead of falling back to this one hook process id.
  _hook_refresh_state_dir
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
      printf '%s\n' "$hint"
      return 0
    }
  fi
  pwd
}

_hook_hm_prompt_text() {
  _hook_hm_read_input
  printf '%s' "${_HOOK_INPUT:-}" | jq -r '
    .prompt // .user_prompt // .message // .input // .tool_input.prompt // empty
  ' 2>/dev/null
}

_hook_hm_tool_status() {
  _hook_hm_read_input
  printf '%s' "${_HOOK_INPUT:-}" | jq -r '
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
  ' 2>/dev/null
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
      inject_context | remind)
        _hook_context "$body"
        ;;
      *)
        _hook_warn "Hive Memory returned unknown hook action: $kind"
        ;;
    esac
  done < <(printf '%s' "$response" | jq -c '.actions[]?' 2>/dev/null)
}

_hook_hm_warn_once() {
  local key="$1" message="$2" marker
  # Hook failures should be visible, but not repeated after every tool call in
  # a long-lived session if a sync mount or config is temporarily unavailable.
  mkdir -p "$_HOOK_STATE_DIR" 2>/dev/null || {
    _hook_warn "$message"
    return 0
  }
  marker="$_HOOK_STATE_DIR/hm-warn-$key"
  [ ! -e "$marker" ] || return 0
  : >"$marker" 2>/dev/null || true
  _hook_warn "$message"
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
      hm_args+=(--project "$project")
      ;;
  esac
  hm_args+=(--json "$@")
  if [ "$project_infer" -eq 0 ]; then
    response=$(
      env -u HIVE_MEMORY_PROJECT \
        HIVE_MEMORY_AGENT_ID="$(_hook_agent_name)" \
        HIVE_MEMORY_SESSION_ID="$_HOOK_SESSION_KEY" \
        HIVE_MEMORY_PROJECT_INFER=0 \
        HIVE_MEMORY_HOOK_ACTIVE=1 \
        hm "${hm_args[@]}" 2>"$err"
    )
  else
    response=$(
      HIVE_MEMORY_AGENT_ID="$(_hook_agent_name)" \
      HIVE_MEMORY_SESSION_ID="$_HOOK_SESSION_KEY" \
      HIVE_MEMORY_PROJECT="$project" \
      HIVE_MEMORY_PROJECT_INFER="$project_infer" \
      HIVE_MEMORY_HOOK_ACTIVE=1 \
        hm "${hm_args[@]}" 2>"$err"
    )
  fi
  rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ -s "$err" ]; then
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
    mkdir -p "$_HOOK_STATE_DIR" 2>/dev/null || return 0
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

# Resolve sibling helpers from this dependency directory. Hook tests commonly
# mock HOME, but helper-to-helper dependencies should follow the library file
# that was actually sourced so partial test homes do not need a second copy.
# shellcheck source=detect.sh
# shellcheck disable=SC1091 # sibling module resolved from this file's dir.
source "$_AGENTGUARD_LIB_DIR/detect.sh"

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
  # Stop-time context is a continuation prompt: block the stop once and ask the
  # agent to handle the reminder before ending the turn.
  printf '%s' "$_HOOK_CTX" | jq -Rsc '{
    decision: "block",
    reason: .
  }'
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
