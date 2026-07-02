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
# Same reasoning for inherited identity env: the runner may be launched by any
# agent (Claude exports CLAUDE_CODE_SESSION_ID into tool subprocesses, Codex
# CODEX_THREAD_ID, etc.). Scrub those so "no env" and explicit-agent fixtures are
# hermetic regardless of which agent runs the suite. Tests that need a signal set
# it explicitly in their own subshell.
unset CLAUDE_CODE_SESSION_ID CLAUDE_CODE_CURRENT_SESSION_ID \
  CODEX_THREAD_ID CODEX_INTERNAL_ORIGINATOR_OVERRIDE GEMINI_PROJECT_DIR
# The hook state root resolves from XDG_RUNTIME_DIR/XDG_STATE_HOME. Scrub the
# ambient values (devservers set XDG_RUNTIME_DIR=/run/user/<uid>) so nothing
# leaks into the real per-user state; the harness re-points XDG_RUNTIME_DIR at
# the test tmpdir once TEST_TMPDIR exists (see below).
unset XDG_RUNTIME_DIR XDG_STATE_HOME
# Dotfiles and other consumers may tune or bypass edit-churn globally. Test
# default behavior against repo defaults; individual tests set custom values
# where that contract is under test.
unset AGENTGUARD_EDIT_CHURN_WARN AGENTGUARD_EDIT_CHURN_BLOCK \
  AGENTGUARD_EDIT_CHURN_BYPASS
# A machine that protects a bare-Git work tree exports these (e.g. a dotfiles
# bare repo). Scrub them so non-protected fixtures stay hermetic regardless of
# the running session; the protected-bare suites set them explicitly via
# _mock_protected_bare_git_home.
unset AGENTGUARD_PROTECTED_BARE_GIT_DIR AGENTGUARD_PROTECTED_BARE_GIT_WORK_TREE \
  AGENTGUARD_PROTECTED_BARE_GIT_ALIASES AGENTGUARD_PROTECTED_BARE_GIT_LAUNCHER \
  AGENTGUARD_PROTECTED_BARE_GIT_STATUS_MESSAGE \
  AGENTGUARD_PROTECTED_BARE_GIT_LS_FILES_MESSAGE \
  AGENTGUARD_PROTECTED_BARE_GIT_CLEAN_MESSAGE

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

# Point the hook state root at the test tmpdir for every fixture and child
# process (hooks resolve state from XDG_RUNTIME_DIR first). Exporting once here
# keeps both spawned hooks and the test process's own _hook_* helpers hermetic,
# so nothing writes into the real ~/.local/state.
#
# Hermeticity contract for new fixtures: rely on this inherited export. A fixture
# that unsets/overrides XDG_RUNTIME_DIR (e.g. to exercise a fallback tier) must
# EITHER only compute the state path without writing, OR also point HOME at a
# temp dir (`_mock_home`) so a resolved ~/.local/state still can't reach the real
# home. Never run a hook that writes state with the ambient HOME and no XDG root.
export XDG_RUNTIME_DIR="$TEST_TMPDIR"

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

# Run a hook with controlled env. Captures stdout into $HOOK_STDOUT, stderr
# into $HOOK_STDERR, and exit code into $HOOK_EXIT. The environment is taken from
# the caller's `_RUN_HOOK_ENV` array (env(1) operands: NAME=value entries and
# `-u NAME` removals); the thin wrappers below differ only in that array.
_run_hook_env() {
  local hook="$1" input="${2:-}"
  # shellcheck disable=SC2034
  HOOK_STDOUT=""
  HOOK_STDERR=""
  HOOK_EXIT=0
  local out_file err_file
  out_file=$(mktemp "$TEST_TMPDIR/out.XXXXXX")
  err_file=$(mktemp "$TEST_TMPDIR/err.XXXXXX")
  if [ -n "$input" ]; then
    printf '%s' "$input" |
      env "${_RUN_HOOK_ENV[@]}" "$hook" >"$out_file" 2>"$err_file" || HOOK_EXIT=$?
  else
    env "${_RUN_HOOK_ENV[@]}" "$hook" >"$out_file" 2>"$err_file" </dev/null || HOOK_EXIT=$?
  fi
  # shellcheck disable=SC2034
  HOOK_STDOUT=$(cat "$out_file")
  HOOK_STDERR=$(cat "$err_file")
  rm -f "$out_file" "$err_file"
}

_run_hook() {
  # shellcheck disable=SC2034  # read by _run_hook_env via dynamic scope.
  local _RUN_HOOK_ENV=(
    AGENTGUARD_SESSION_ID="$TEST_SID"
    TMPDIR="$TEST_TMPDIR"
    AGENTGUARD_NAME="agent"
    CODEX_THREAD_ID=
  )
  _run_hook_env "$@"
}

_run_hook_with_git_env() {
  # shellcheck disable=SC2034  # read by _run_hook_env via dynamic scope.
  local _RUN_HOOK_ENV=(
    GIT_DIR="$HOME/.protected-bare-git"
    GIT_WORK_TREE="$HOME"
    AGENTGUARD_SESSION_ID="$TEST_SID"
    TMPDIR="$TEST_TMPDIR"
    AGENTGUARD_NAME="agent"
    CODEX_THREAD_ID=
  )
  _run_hook_env "$@"
}

_run_hook_without_user() {
  # shellcheck disable=SC2034  # read by _run_hook_env via dynamic scope.
  local _RUN_HOOK_ENV=(
    -u USER
    AGENTGUARD_SESSION_ID="$TEST_SID"
    TMPDIR="$TEST_TMPDIR"
    AGENTGUARD_NAME="agent"
    CODEX_THREAD_ID=
  )
  _run_hook_env "$@"
}

# Run a hook with Gemini env vars instead of Claude. Same capture contract.
_run_hook_gemini() {
  # shellcheck disable=SC2034  # read by _run_hook_env via dynamic scope.
  local _RUN_HOOK_ENV=(
    GEMINI_PROJECT_DIR="$TEST_TMPDIR"
    AGENTGUARD_SESSION_ID=
    CLAUDE_CODE_CURRENT_SESSION_ID=
    AGENTGUARD_NAME="gemini"
    TMPDIR="$TEST_TMPDIR"
  )
  _run_hook_env "$@"
}

# Clean hook state between tests
_reset_state() {
  rm -rf "$TEST_TMPDIR/agentguard/hook-state/$TEST_SID"
}
