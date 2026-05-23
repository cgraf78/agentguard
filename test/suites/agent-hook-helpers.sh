#!/usr/bin/env bash
# agent-hook-helpers.sh — shared setup for AI agent hook test shards.

# shellcheck disable=SC1090,SC1091,SC2030,SC2031,SC2034 # dynamic sources, subshell fixtures, shared fixture vars
set -o pipefail
export NO_COLOR=1
export AGENTGUARD_HIVE_MEMORY_HOOKS=0
# The test runner may itself be launched by Codex. Most hook fixtures below set
# explicit agent env, and the "no env" cases should stay no-env even when
# their parent process is Codex.
export AGENTGUARD_PROCESS_DETECT=0

AGENTGUARD_TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
AGENTGUARD_ROOT="$(cd -- "$AGENTGUARD_TEST_DIR/.." && pwd -P)"
AGENTGUARD_REAL_HOME="$HOME"
export AGENTGUARD_ROOT AGENTGUARD_REAL_HOME

BIN_DIR="$AGENTGUARD_ROOT/bin"
HELPERS="$AGENTGUARD_ROOT/lib/agentguard/hook-helpers.sh"

# shellcheck source=../helpers.sh
. "$AGENTGUARD_TEST_DIR/helpers.sh"

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

TEST_TMPDIR=$(_tmpdir)
TEST_SID="agent-hook-test-$$"

PRE_MCP="$BIN_DIR/agent-hook-pre-mcp"
POST_MCP="$BIN_DIR/agent-hook-post-mcp"
PRE_BASH="$BIN_DIR/agent-hook-pre-bash"
PRE_EDIT="$BIN_DIR/agent-hook-pre-edit"
POST_EDIT="$BIN_DIR/agent-hook-post-edit"
SESSION_START="$BIN_DIR/agent-hook-session-start"

_install_hook_fixture() {
  local install_dir="$1" hook
  shift

  mkdir -p "$install_dir/bin" "$install_dir/lib/agentguard"
  cp "$AGENTGUARD_ROOT"/lib/agentguard/*.sh "$install_dir/lib/agentguard/"
  for hook in "$@"; do
    cp "$BIN_DIR/$hook" "$install_dir/bin/$hook"
    chmod +x "$install_dir/bin/$hook"
  done
}

_mock_protected_bare_git_home() {
  local real_git candidate
  while IFS= read -r candidate; do
    case "$candidate" in
      "$AGENTGUARD_REAL_HOME/.local/bin/git")
        continue
        ;;
    esac
    [ -x "$candidate" ] || continue
    real_git="$candidate"
    break
  done < <(type -P -a git 2>/dev/null)
  [ -n "${real_git:-}" ] || real_git=/usr/bin/git

  _mock_home
  mkdir -p "$HOME/.protected-bare-git" "$HOME/.local/bin" "$HOME/.normal-git-repo"
  printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$real_git" >"$HOME/.local/bin/git"
  chmod +x "$HOME/.local/bin/git"
  export AGENTGUARD_PROTECTED_BARE_GIT_DIR="$HOME/.protected-bare-git"
  export AGENTGUARD_PROTECTED_BARE_GIT_WORK_TREE="$HOME"
  export AGENTGUARD_PROTECTED_BARE_GIT_ALIASES="BARE_HOME_GIT"
  export AGENTGUARD_PROTECTED_BARE_GIT_LAUNCHER="$HOME/.local/bin/git"
  export AGENTGUARD_PROTECTED_BARE_GIT_STATUS_MESSAGE="do not run protected bare-Git status with untracked files enabled; inspect a scoped path instead."
  export AGENTGUARD_PROTECTED_BARE_GIT_LS_FILES_MESSAGE="do not list every untracked file in the protected bare-Git repo; use -- <path> for a scoped check."
  export AGENTGUARD_PROTECTED_BARE_GIT_CLEAN_MESSAGE="do not run unscoped git clean in the protected bare-Git repo; inspect a scoped path instead."

  # The protected-bare guard models the PATH-visible git launcher only when the
  # command would run from the broad work tree or a non-repo descendant. Keep
  # that ambient context hermetic so these suites can run anywhere.
  git init -q "$HOME/.normal-git-repo"
  cd -- "$HOME" || exit 1
}

# Several shards need the same synthetic apply_patch payload. Keep it here so
# parser and edit-hook tests exercise the same fixture shape.
_apply_patch_json=$(jq -n --arg patch \
  "$(printf '%s\n' \
    "*** Begin Patch" \
    "*** Update File: /tmp/test/a.py" \
    "@@" \
    "-old" \
    "+new" \
    "*** Update File: /tmp/test/b.py" \
    "*** Move to: /tmp/test/c.py" \
    "@@" \
    "-old" \
    "+new" \
    "*** End Patch")" \
  '{"tool_input":$patch}')

# Run a hook with controlled env. Captures stderr into $HOOK_STDERR,
# stdout into $HOOK_STDOUT, and exit code into $HOOK_EXIT.
_run_hook() {
  local hook="$1"
  shift
  local input="${1:-}"
  # shellcheck disable=SC2034
  HOOK_STDOUT=""
  HOOK_STDERR=""
  HOOK_EXIT=0
  local out_file err_file
  out_file=$(mktemp "$TEST_TMPDIR/out.XXXXXX")
  err_file=$(mktemp "$TEST_TMPDIR/err.XXXXXX")
  if [ -n "$input" ]; then
    printf '%s' "$input" |
      AGENTGUARD_SESSION_ID="$TEST_SID" \
        TMPDIR="$TEST_TMPDIR" \
        AGENTGUARD_NAME="agent" \
        CODEX_THREAD_ID="" \
        "$hook" >"$out_file" 2>"$err_file" || HOOK_EXIT=$?
  else
    AGENTGUARD_SESSION_ID="$TEST_SID" \
      TMPDIR="$TEST_TMPDIR" \
      AGENTGUARD_NAME="agent" \
      CODEX_THREAD_ID="" \
      "$hook" >"$out_file" 2>"$err_file" </dev/null || HOOK_EXIT=$?
  fi
  # shellcheck disable=SC2034
  HOOK_STDOUT=$(cat "$out_file")
  HOOK_STDERR=$(cat "$err_file")
  rm -f "$out_file" "$err_file"
}

_run_hook_with_git_env() {
  local hook="$1"
  shift
  local input="${1:-}"
  # shellcheck disable=SC2034
  HOOK_STDOUT=""
  HOOK_STDERR=""
  HOOK_EXIT=0
  local out_file err_file
  out_file=$(mktemp "$TEST_TMPDIR/out.XXXXXX")
  err_file=$(mktemp "$TEST_TMPDIR/err.XXXXXX")
  if [ -n "$input" ]; then
    printf '%s' "$input" |
      GIT_DIR="$HOME/.protected-bare-git" \
        GIT_WORK_TREE="$HOME" \
        AGENTGUARD_SESSION_ID="$TEST_SID" \
        TMPDIR="$TEST_TMPDIR" \
        AGENTGUARD_NAME="agent" \
        CODEX_THREAD_ID="" \
        "$hook" >"$out_file" 2>"$err_file" || HOOK_EXIT=$?
  else
    GIT_DIR="$HOME/.protected-bare-git" \
      GIT_WORK_TREE="$HOME" \
      AGENTGUARD_SESSION_ID="$TEST_SID" \
      TMPDIR="$TEST_TMPDIR" \
      AGENTGUARD_NAME="agent" \
      CODEX_THREAD_ID="" \
      "$hook" >"$out_file" 2>"$err_file" </dev/null || HOOK_EXIT=$?
  fi
  # shellcheck disable=SC2034
  HOOK_STDOUT=$(cat "$out_file")
  HOOK_STDERR=$(cat "$err_file")
  rm -f "$out_file" "$err_file"
}

_run_hook_without_user() {
  local hook="$1"
  shift
  local input="${1:-}"
  # shellcheck disable=SC2034
  HOOK_STDOUT=""
  HOOK_STDERR=""
  HOOK_EXIT=0
  local out_file err_file
  out_file=$(mktemp "$TEST_TMPDIR/out.XXXXXX")
  err_file=$(mktemp "$TEST_TMPDIR/err.XXXXXX")
  if [ -n "$input" ]; then
    printf '%s' "$input" |
      env -u USER \
        AGENTGUARD_SESSION_ID="$TEST_SID" \
        TMPDIR="$TEST_TMPDIR" \
        AGENTGUARD_NAME="agent" \
        CODEX_THREAD_ID="" \
        "$hook" >"$out_file" 2>"$err_file" || HOOK_EXIT=$?
  else
    env -u USER \
      AGENTGUARD_SESSION_ID="$TEST_SID" \
      TMPDIR="$TEST_TMPDIR" \
      AGENTGUARD_NAME="agent" \
      CODEX_THREAD_ID="" \
      "$hook" >"$out_file" 2>"$err_file" </dev/null || HOOK_EXIT=$?
  fi
  # shellcheck disable=SC2034
  HOOK_STDOUT=$(cat "$out_file")
  HOOK_STDERR=$(cat "$err_file")
  rm -f "$out_file" "$err_file"
}

# Run a hook with Gemini env vars instead of Claude. Same capture contract.
_run_hook_gemini() {
  local hook="$1"
  shift
  local input="${1:-}"
  # shellcheck disable=SC2034
  HOOK_STDOUT=""
  HOOK_STDERR=""
  HOOK_EXIT=0
  local out_file err_file
  out_file=$(mktemp "$TEST_TMPDIR/out.XXXXXX")
  err_file=$(mktemp "$TEST_TMPDIR/err.XXXXXX")
  if [ -n "$input" ]; then
    printf '%s' "$input" |
      GEMINI_PROJECT_DIR="$TEST_TMPDIR" \
        AGENTGUARD_SESSION_ID="" \
        CLAUDE_CODE_CURRENT_SESSION_ID="" \
        AGENTGUARD_NAME="gemini" \
        TMPDIR="$TEST_TMPDIR" \
        "$hook" >"$out_file" 2>"$err_file" || HOOK_EXIT=$?
  else
    GEMINI_PROJECT_DIR="$TEST_TMPDIR" \
      AGENTGUARD_SESSION_ID="" \
      CLAUDE_CODE_CURRENT_SESSION_ID="" \
      AGENTGUARD_NAME="gemini" \
      TMPDIR="$TEST_TMPDIR" \
      "$hook" >"$out_file" 2>"$err_file" </dev/null || HOOK_EXIT=$?
  fi
  # shellcheck disable=SC2034
  HOOK_STDOUT=$(cat "$out_file")
  HOOK_STDERR=$(cat "$err_file")
  rm -f "$out_file" "$err_file"
}

# Clean hook state between tests
_reset_state() {
  rm -rf "$TEST_TMPDIR/hook-state/$TEST_SID"
}
