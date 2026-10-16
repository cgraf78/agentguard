#!/usr/bin/env bash
# shellcheck shell=bash
# watch-github.sh — GitHub pull-request vocabulary for the watch engine.
#
# The one place AgentGuard maps GitHub URLs and `git push` output onto the
# keys and scopes `git pr-watch` (git-tools) publishes. git-pr-watch(1),
# section STATE FILES, is the normative contract: a pull request's key is
# <owner>_<repository>_<number> and its repository's scope is
# <owner>_<repository>, both taken from the URL path and lowercased. Keys and
# scopes are compared whole, never split; the push re-arm's same-repository
# fallback below is the one documented exception.
#
# A documented API: post-bash calls it for commands it recognizes, and hook
# extensions call it for wrapped commands that create pull requests or push
# (then _hook_watch_record / _hook_watch_rearm from watch.sh). Loaded lazily
# (_hook_load_watch_github); Bash 3.2 compatible, `set -u` clean, never exits.

# The producer's state dir relative to a state root, its watcher program, and
# the variable that turns its state files off. Owned by git-tools; kept here
# so every AgentGuard caller shares one spelling.
_HOOK_GH_PR_TOOL_DIR='git-tools/pr-watch'
_HOOK_GH_PR_WATCH_ARGV='git-pr-watch'
_HOOK_GH_PR_STATE_VAR='GIT_PR_WATCH_STATE'

# Lowercase ASCII $2 into the variable named by $1 without a fork, as the
# producer does (`LC_ALL=C tr`). Bash 4 lowercases in one expansion, but by
# the caller's locale (Turkish maps `I` to a dotless `ı`), so a result that
# is not plain ASCII falls back to the walk Bash 3.2 always uses, a
# character at a time over the (length-capped, see _hook_gh_owner_repo_ok)
# name.
_hook_gh_lower() {
  # Prefixed locals: $1 names a variable in the caller's scope.
  local _lc_in="$2" _lc_out='' _lc_c _lc_i _lc_upper='ABCDEFGHIJKLMNOPQRSTUVWXYZ'
  local _lc_lower='abcdefghijklmnopqrstuvwxyz' _lc_prefix
  if [ "${BASH_VERSINFO[0]:-0}" -ge 4 ]; then
    _lc_out="${_lc_in,,}"
    case "$_lc_out" in
      *[!abcdefghijklmnopqrstuvwxyz0123456789._-]*) _lc_out='' ;;
      *)
        printf -v "$1" '%s' "$_lc_out"
        return 0
        ;;
    esac
  fi
  for ((_lc_i = 0; _lc_i < ${#_lc_in}; _lc_i++)); do
    _lc_c="${_lc_in:_lc_i:1}"
    case "$_lc_c" in
      [ABCDEFGHIJKLMNOPQRSTUVWXYZ])
        _lc_prefix="${_lc_upper%%"$_lc_c"*}"
        _lc_c="${_lc_lower:${#_lc_prefix}:1}"
        ;;
    esac
    _lc_out="$_lc_out$_lc_c"
  done
  printf -v "$1" '%s' "$_lc_out"
}

# Whether $1 is a GitHub owner or repository name as the producer accepts it.
_hook_gh_name_ok() {
  case "${1:-}" in
    '' | . | .. | *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# Whether $1 and $2 are a valid owner and repository name, within GitHub's
# own length limits (39 and 100). The cap also bounds the work every later
# string operation does on a hostile name.
_hook_gh_owner_repo_ok() {
  [ "${#1}" -le 39 ] && [ "${#2}" -le 100 ] &&
    _hook_gh_name_ok "$1" && _hook_gh_name_ok "$2"
}

# _hook_gh_pr_key_scope <url>
#
# Map a pull-request URL (`https://<any host>/<owner>/<repo>/pull/<number>`,
# optionally followed by `/...`, `?...`, or `#...`) to its key and scope.
# Sets _HOOK_GH_PR_KEY, _HOOK_GH_PR_SCOPE, and _HOOK_GH_PR_NUMBER and prints
# "<key> <scope>"; fails for anything else. The host is not part of either,
# as the producer contract documents.
_hook_gh_pr_key_scope() {
  local url="${1:-}" rest owner repo marker number scope
  _HOOK_GH_PR_KEY=''
  _HOOK_GH_PR_SCOPE=''
  _HOOK_GH_PR_NUMBER=''
  case "$url" in
    https://* | http://*) rest="${url#*://}" ;;
    *) return 1 ;;
  esac
  # Host, then the path. Only host-name characters: a label is echoed into a
  # suggested command, so shell syntax must never get through.
  case "${rest%%/*}" in
    '' | *[!A-Za-z0-9.-]*) return 1 ;;
  esac
  case "$rest" in */*) ;; *) return 1 ;; esac
  rest="${rest#*/}"
  owner="${rest%%/*}"
  rest="${rest#*/}"
  repo="${rest%%/*}"
  rest="${rest#*/}"
  marker="${rest%%/*}"
  rest="${rest#"$marker"}"
  number="${rest#/}"
  number="${number%%[/?#]*}"
  [ "$marker" = pull ] || return 1
  case "$number" in
    '' | 0* | *[!0-9]*) return 1 ;;
  esac
  if ! _hook_gh_owner_repo_ok "$owner" "$repo"; then
    return 1
  fi
  _hook_gh_lower scope "${owner}_$repo"
  _HOOK_GH_PR_KEY="${scope}_$number"
  _HOOK_GH_PR_SCOPE="$scope"
  _HOOK_GH_PR_NUMBER="$number"
  printf '%s %s\n' "$_HOOK_GH_PR_KEY" "$_HOOK_GH_PR_SCOPE"
}

# Store in the variable named by $1 the scope of a push URL $2: its path's
# last two components, split on `/` or `:` so scp-style `git@alias:o/r.git`
# works, with a trailing `/` and `.git` removed, lowercased. Also stores the
# lowercased repository part in _HOOK_GH_PUSH_REPO. Fails when the URL has no
# owner component or a component is not a valid name.
_hook_gh_push_url_scope() {
  local url="$2" repo rest owner
  while :; do
    case "$url" in
      */) url="${url%/}" ;;
      *) break ;;
    esac
  done
  url="${url%.git}"
  repo="${url##*[:/]}"
  [ "$repo" != "$url" ] || return 1
  rest="${url%[:/]*}"
  owner="${rest##*[:/]}"
  if ! _hook_gh_owner_repo_ok "$owner" "$repo"; then
    return 1
  fi
  _hook_gh_lower _HOOK_GH_PUSH_REPO "$repo"
  _hook_gh_lower "$1" "${owner}_$repo"
}

# Whether push output line $1 reports a successful update of a non-tag ref.
# Human format: ` <flag> <summary> <from> -> <to>` with flag ` ` (fast
# forward), `+` (forced), or `*` (new ref). Porcelain format:
# `<flag>\t<from>:<to>\t<summary>`. Rejected (`!`), up-to-date (`=`), and
# deleted (`-`) refs never count, nor do tags.
_hook_gh_push_line_updates() {
  local line="$1" tab=$'\t' refs
  case "$line" in
    [\ +*]"$tab"*"$tab"*)
      refs="${line#?"$tab"}"
      refs="${refs%%"$tab"*}"
      case "${refs#*:}" in refs/tags/*) return 1 ;; esac
      return 0
      ;;
    \ [\ +*]\ *' -> '*)
      case "$line" in *'[new tag]'* | *' -> refs/tags/'*) return 1 ;; esac
      return 0
      ;;
  esac
  return 1
}

# Whether push command $1 cannot update refs or does not push at all: a dry
# run, a deletion, `--no-push` (stack tools), or a usage request. Sets
# _HOOK_GH_PUSH_WORD=1 when the command has a `push` word (`git push`, or a
# wrapper's push subcommand). A plain word check; post-bash already judges
# `git push` with the command classifier.
_hook_gh_push_command_inert() {
  local word
  local -a words=()
  _HOOK_GH_PUSH_WORD=0
  read -r -a words <<<"${1:-}"
  for word in ${words[@]+"${words[@]}"}; do
    word="${word#[\"\']}"
    word="${word%[\"\']}"
    case "$word" in
      --dry-run | -n | --no-push | --delete | -d | -h | --help) return 0 ;;
      push | */git-push | git-push) _HOOK_GH_PUSH_WORD=1 ;;
    esac
  done
  return 1
}

# Add the scope of push block URL $1 to the caller's `pushed` list when the
# block counted, once per URL and once per scope. A push has a handful of
# remotes, so collection stops at 64 distinct URLs and sets `overflow`
# instead (the caller then re-arms everything): the membership tests scan
# the growing lists, which would turn quadratic on output with thousands of
# blocks. Uses the caller's counted, urls, nurls, overflow, and pushed
# (dynamic scope; _hook_gh_push_scopes only).
_hook_gh_push_count_block() {
  local _cb_scope
  [ "$counted" = 1 ] || return 0
  [ "$overflow" = 0 ] || return 0
  case "$urls" in *" $1 "*) return 0 ;; esac
  if [ "$nurls" -ge 64 ]; then
    overflow=1
    return 0
  fi
  nurls=$((nurls + 1))
  urls="$urls$1 "
  _hook_gh_push_url_scope _cb_scope "$1" || return 0
  case "$pushed" in *" $_cb_scope/"*) return 0 ;; esac
  pushed="$pushed $_cb_scope/$_HOOK_GH_PUSH_REPO "
}

# _hook_gh_push_scopes <output> <command>
#
# Print the recorded scopes a successful push re-arms, one per line, `ALL`,
# or nothing. <output> is the push's stdout and stderr; <command> is the
# command that pushed. Rules:
#   - an inert command (see _hook_gh_push_command_inert) re-arms nothing;
#   - each `To <url>` block counts only with at least one successful non-tag
#     update line; its scope comes from the URL (_hook_gh_push_url_scope);
#   - counted scopes this session recorded re-arm exactly those;
#   - a counted block matching no recorded scope re-arms recorded scopes
#     ending in `_<repository>` (a fork keeps the repository name); this is
#     the one place a scope is compared by part, so it can also re-arm a
#     recorded scope whose repository name merely ends that way, and a
#     renamed repository is a documented gap;
#   - with no `To` block and no `Everything up-to-date`, blank output (a
#     quiet or redirected push, from any command) re-arms ALL, and so does
#     other output from a command with a `push` word; other output from any
#     other command (a stack tool saying it had nothing to push) re-arms
#     nothing;
#   - an up-to-date, rejected-only, or tag-only push re-arms nothing;
#   - more than 64 distinct counted `To` URLs re-arm ALL (no push has that
#     many remotes; the cap bounds the work on hostile output).
# The caller checks the push succeeded; a failed push never re-arms.
_hook_gh_push_scopes() {
  local output="$1" command="${2:-}" line url='' counted=0 blocks=0 uptodate=0
  local pushed='' urls=' ' nurls=0 overflow=0 recorded='' pair scope repo rscope
  _hook_gh_push_command_inert "$command" && return 0
  # Counted blocks collect as " <scope>/<repo> " pairs (neither holds `/`).
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line//$'\r'/}"
    case "$line" in
      'To '*)
        _hook_gh_push_count_block "$url"
        url="${line#To }"
        url="${url%%[[:space:]]*}"
        counted=0
        blocks=1
        ;;
      'Everything up-to-date'*) uptodate=1 ;;
      *)
        if [ -n "$url" ] && [ "$counted" = 0 ] && _hook_gh_push_line_updates "$line"; then
          counted=1
        fi
        ;;
    esac
  done <<<"$output"
  _hook_gh_push_count_block "$url"
  if [ "$overflow" = 1 ]; then
    printf 'ALL\n'
    return 0
  fi
  if [ "$blocks" = 0 ]; then
    [ "$uptodate" = 0 ] || return 0
    case "$output" in
      *[![:space:]]*) [ "$_HOOK_GH_PUSH_WORD" = 0 ] || printf 'ALL\n' ;;
      *) printf 'ALL\n' ;;
    esac
    return 0
  fi
  [ -n "$pushed" ] || return 0
  # Recorded scopes, each once.
  while read -r _ rscope _; do
    [ -n "$rscope" ] && [ "$rscope" != - ] || continue
    case "$recorded" in *" $rscope "*) ;; *) recorded="$recorded $rscope " ;; esac
  done < <(_hook_watch_list "$_HOOK_GH_PR_TOOL_DIR")
  for rscope in $recorded; do
    for pair in $pushed; do
      scope="${pair%/*}"
      repo="${pair#*/}"
      # An exact match, or a pushed scope nobody recorded (a fork) whose
      # repository part matches the recorded scope's tail.
      if [ "$scope" = "$rscope" ]; then
        printf '%s\n' "$rscope"
        continue 2
      fi
      case "$recorded" in *" $scope "*) continue ;; esac
      case "$rscope" in
        *"_$repo")
          printf '%s\n' "$rscope"
          continue 2
          ;;
      esac
    done
  done
  return 0
}

# _hook_gh_watch_chain <variable>
#
# pre-bash only (needs the command classifier). Store in the variable named
# by $1 the first command in the hook's command that records or re-arms a
# pull request (`git push`, `git pr-open|pr-submit|pr-restack|pr-sync-stack`
# or their dashed forms, `gh pr create|new|ready|reopen|update-branch`), as a
# short display form, and succeed; fail when there is none. A watcher chained
# behind one of those in one tool call is killed with it in the foreground,
# and in the background post-bash sees the call before the push or the new
# pull request exists.
_hook_gh_watch_chain() {
  local fragment word sub index
  local -a words=()
  case "${AGENTGUARD_CMD_TRIMMED:-}" in
    *push* | *pr-open* | *pr-submit* | *pr-restack* | *pr-sync-stack* | *gh*) ;;
    *) return 1 ;;
  esac
  if [ "${_HOOK_EXECUTABLE_FRAGMENTS_CACHE_TEXT+x}" != x ] ||
    [ "$_HOOK_EXECUTABLE_FRAGMENTS_CACHE_TEXT" != "$AGENTGUARD_CMD_TRIMMED" ]; then
    _hook_cache_executable_fragments "$AGENTGUARD_CMD_TRIMMED"
  fi
  while IFS= read -r fragment; do
    case "$fragment" in
      *push* | *pr-open* | *pr-submit* | *pr-restack* | *pr-sync-stack*)
        for sub in push pr-open pr-submit pr-restack pr-sync-stack; do
          if _git_subcommand_is "$fragment" "$sub"; then
            printf -v "$1" '%s' "git $sub"
            return 0
          fi
        done
        _fragment_command_word "$fragment" word || continue
        word="${word##*/}"
        case "$word" in
          git-pr-open | git-pr-submit | git-pr-restack | git-pr-sync-stack)
            printf -v "$1" '%s' "git ${word#git-}"
            return 0
            ;;
        esac
        ;;
    esac
    case "$fragment" in *gh*pr*) ;; *) continue ;; esac
    _command_subcommand_index "$fragment" gh pr index || continue
    words=()
    _fragment_token_words "$fragment" words
    for ((index++; index < ${#words[@]}; index++)); do
      _clean_command_word "${words[index]}" word
      case "$word" in
        -R | --repo) index=$((index + 1)) ;;
        -*) ;;
        create | new | ready | reopen | update-branch)
          printf -v "$1" '%s' "gh pr $word"
          return 0
          ;;
        *) break ;;
      esac
    done
  done <<<"$_HOOK_EXECUTABLE_FRAGMENTS_CACHE_VALUE"
  return 1
}

# --- The post-bash watch pass ---
#
# One implementation of what post-bash does for a command that pushes or
# opens a pull request, shared with hook extensions that unwrap commands the
# base pass cannot see (a wrapper that runs `git push` for the agent). The
# classifier-based helpers below need Bash 4, like post-bash's classifier.

# Whether git push fragment $1 updates remote refs: dry runs, deletions
# (`--delete`, `-d`, clustered short flags, `:ref` refspecs), and usage
# requests do not.
_hook_gh_push_updates() {
  local fragment="$1" word index
  local -a words=()
  _fragment_token_words "$fragment" words
  _git_subcommand_index "$fragment" push index || return 1
  for ((index++; index < ${#words[@]}; index++)); do
    _clean_command_word "${words[$index]}" word
    case "$word" in
      --) break ;;
      --dry-run | --delete | --help | -h | :?*) return 1 ;;
      --*) ;;
      -*n* | -*d*) return 1 ;;
    esac
  done
  return 0
}

# Whether gh fragment $1 runs a pull-request subcommand that pushes or opens
# a pull request for review: create (or its alias new), ready, reopen, or
# update-branch, judged by the word in subcommand position rather than
# anywhere in the text. Stores that subcommand in _HOOK_GH_W_SUB.
_hook_gh_pr_starts_checks() {
  local fragment="$1" word index
  local -a words=()
  _HOOK_GH_W_SUB=''
  _fragment_token_words "$fragment" words
  _command_subcommand_index "$fragment" gh pr index || return 1
  for ((index++; index < ${#words[@]}; index++)); do
    _clean_command_word "${words[$index]}" word
    case "$word" in
      -R | --repo) ((index++)) ;;
      -*) ;;
      create | new)
        _command_subcommand_has_option "$fragment" gh pr --dry-run && return 1
        _HOOK_GH_W_SUB=create
        return 0
        ;;
      ready)
        _command_subcommand_has_option "$fragment" gh pr --undo && return 1
        _HOOK_GH_W_SUB=ready
        return 0
        ;;
      reopen | update-branch)
        _HOOK_GH_W_SUB="$word"
        return 0
        ;;
      *) return 1 ;;
    esac
  done
  return 1
}

# Store the target of `gh pr ready|reopen|update-branch` fragment $1 as
# "<repo> <arg>" in _HOOK_GH_W_TARGET: the `-R`/`--repo` value anywhere after
# gh (or `-`) and the first positional after the subcommand (or `-`).
_hook_gh_pr_target() {
  local fragment="$1" word index sub_seen=0 repo=- arg=-
  local -a words=()
  _fragment_token_words "$fragment" words
  _fragment_command_index "$fragment" index || return 1
  for ((index++; index < ${#words[@]}; index++)); do
    _clean_command_word "${words[$index]}" word
    case "$word" in
      --) break ;;
      -R | --repo)
        ((index++))
        _clean_command_word "${words[$index]:-}" repo
        ;;
      -R?*) repo="${word#-R}" ;;
      --repo=*) repo="${word#--repo=}" ;;
      # `gh pr reopen --comment <text>`: the text is not the target.
      -c | --comment) ((index++)) ;;
      -*) ;;
      pr) [ "$sub_seen" -gt 0 ] || sub_seen=1 ;;
      *)
        if [ "$sub_seen" = 1 ]; then
          sub_seen=2
        elif [ "$sub_seen" = 2 ] && [ "$arg" = - ]; then
          arg="$word"
        fi
        ;;
    esac
  done
  _HOOK_GH_W_TARGET="${repo:--} ${arg:--}"
}

# Whether git fragment $1 runs subcommand $2 (or its dashed `git-$2` form)
# for real: not a dry run, not `--no-push`, and not a usage request.
_hook_gh_git_runs() {
  local fragment="$1" sub="$2" word index
  local -a words=()
  _fragment_token_words "$fragment" words
  if ! _git_subcommand_index "$fragment" "$sub" index; then
    _fragment_command_index "$fragment" index || return 1
    _clean_command_word "${words[$index]}" word
    [ "${word##*/}" = "git-$sub" ] || return 1
  fi
  for ((index++; index < ${#words[@]}; index++)); do
    _clean_command_word "${words[$index]}" word
    case "$word" in
      --) break ;;
      -n | --dry-run | --no-push | -h | --help) return 1 ;;
    esac
  done
  return 0
}

# Classify the executable fragments of command text $1. Sets
# _HOOK_GH_W_CREATES (a pull request was created: `gh pr create|new`, `git
# pr-open`, `git pr-submit`), _HOOK_GH_W_PUSH (a push: `git push`, `git
# pr-restack`, `git pr-sync-stack`, its fragment in _HOOK_GH_W_PUSH_FRAGMENT),
# and _HOOK_GH_W_TARGETS (one "<repo> <arg>" per `gh pr
# ready|reopen|update-branch`). Succeeds when any of them started checks.
_hook_gh_classify() {
  local fragment found=1
  _HOOK_GH_W_CREATES='' _HOOK_GH_W_PUSH='' _HOOK_GH_W_PUSH_FRAGMENT=''
  _HOOK_GH_W_TARGETS=()
  _hook_load_command_classifier || return 1
  while IFS= read -r fragment; do
    if _git_subcommand_is "$fragment" push; then
      if _hook_gh_push_updates "$fragment"; then
        _HOOK_GH_W_PUSH=1
        _HOOK_GH_W_PUSH_FRAGMENT="${_HOOK_GH_W_PUSH_FRAGMENT:-$fragment}"
        found=0
      fi
    elif _command_subcommand_is "$fragment" gh pr; then
      _hook_gh_pr_starts_checks "$fragment" || continue
      found=0
      if [ "$_HOOK_GH_W_SUB" = create ]; then
        _HOOK_GH_W_CREATES=1
      elif _hook_gh_pr_target "$fragment"; then
        _HOOK_GH_W_TARGETS+=("$_HOOK_GH_W_TARGET")
      fi
    else
      # A builtin match first: tokenizing every other fragment four more
      # times would slow long scripts that end in a push.
      case "$fragment" in
        *pr-open* | *pr-submit*)
          if _hook_gh_git_runs "$fragment" pr-open || _hook_gh_git_runs "$fragment" pr-submit; then
            _HOOK_GH_W_CREATES=1
            found=0
          fi
          ;;
        *pr-restack* | *pr-sync-stack*)
          if _hook_gh_git_runs "$fragment" pr-restack || _hook_gh_git_runs "$fragment" pr-sync-stack; then
            _HOOK_GH_W_PUSH=1
            _HOOK_GH_W_PUSH_FRAGMENT="${_HOOK_GH_W_PUSH_FRAGMENT:-$fragment}"
            found=0
          fi
          ;;
      esac
    fi
  done < <(_hook_executable_fragments "$1")
  return "$found"
}

# Append the labels a record or re-arm printed (one per line) to
# _HOOK_GH_W_LABELS, each once.
_hook_gh_add_labels() {
  local label
  while IFS= read -r label; do
    [ -n "$label" ] || continue
    case " $_HOOK_GH_W_LABELS " in
      *" $label "*) ;;
      *) _HOOK_GH_W_LABELS="$_HOOK_GH_W_LABELS $label" ;;
    esac
  done <<<"$1"
}

# Record each pull request whose bare URL line output $1 holds, with hint
# $2. Only with `git pr-watch` installed: without the producer the
# obligation could never be met.
_hook_gh_record_output() {
  local line
  command -v "$_HOOK_GH_PR_WATCH_ARGV" >/dev/null 2>&1 || return 0
  while IFS= read -r line; do
    [[ "$line" =~ ^$_HOOK_GH_PR_URL_RE ]] || continue
    line="${line%%[[:space:]]*}"
    _hook_gh_pr_key_scope "$line" >/dev/null || continue
    _hook_watch_record "$_HOOK_GH_PR_TOOL_DIR" "$_HOOK_GH_PR_KEY" "$_HOOK_GH_PR_SCOPE" \
      "$_HOOK_GH_PR_WATCH_ARGV" "$line" "$2" &&
      _HOOK_GH_W_LABELS="$_HOOK_GH_W_LABELS $line"
  done <<<"$1"
}

# Re-arm recorded pull requests the `gh pr ready|reopen|update-branch`
# targets in _HOOK_GH_W_TARGETS named: a URL, or `-R owner/repo` (or
# host/owner/repo) plus a number, names one key; a bare number names every
# recorded key of that number (how a closed pull request is revived on
# reopen); a branch or no argument re-arms all.
_hook_gh_rearm_targets() {
  local target repo arg key owner name
  for target in ${_HOOK_GH_W_TARGETS[@]+"${_HOOK_GH_W_TARGETS[@]}"}; do
    repo="${target%% *}"
    arg="${target#* }"
    arg="${arg#\#}"
    if _hook_gh_pr_key_scope "$arg" >/dev/null; then
      _hook_gh_add_labels "$(_hook_watch_rearm_key "$_HOOK_GH_PR_TOOL_DIR" "$_HOOK_GH_PR_KEY")"
    elif [[ "$arg" =~ ^[1-9][0-9]*$ ]]; then
      if [ "$repo" != - ]; then
        name="${repo##*/}"
        owner="${repo%/*}"
        owner="${owner##*/}"
        if ! _hook_gh_owner_repo_ok "$owner" "$name"; then
          continue
        fi
        _hook_gh_lower key "${owner}_${name}_$arg"
        _hook_gh_add_labels "$(_hook_watch_rearm_key "$_HOOK_GH_PR_TOOL_DIR" "$key")"
      else
        while read -r key _; do
          [[ "$key" == *"_$arg" ]] || continue
          _hook_gh_add_labels "$(_hook_watch_rearm_key "$_HOOK_GH_PR_TOOL_DIR" "$key")"
        done < <(_hook_watch_list "$_HOOK_GH_PR_TOOL_DIR")
      fi
    else
      _hook_gh_add_labels "$(_hook_watch_rearm "$_HOOK_GH_PR_TOOL_DIR" ALL)"
    fi
  done
}

# Re-arm recorded pull requests a successful push updated (see
# _hook_gh_push_scopes), from output $1. Push summaries go to stderr, so the
# hook payload's stderr is read as well unless the payload already holds a
# combined Codex or Muse string.
_hook_gh_rearm_pushed() {
  local text="$1" scope scopes=()
  # stderr: the setlocale warning a local C locale prints on restore.
  _hook_tool_response_is_string 2>/dev/null || text="$text"$'\n'"$(_hook_tool_stderr)"
  while IFS= read -r scope; do
    [ -n "$scope" ] && scopes+=("$scope")
  done < <(_hook_gh_push_scopes "$text" "$_HOOK_GH_W_PUSH_FRAGMENT")
  [ "${#scopes[@]}" -gt 0 ] || return 0
  _hook_gh_add_labels "$(_hook_watch_rearm "$_HOOK_GH_PR_TOOL_DIR" "${scopes[@]}")"
}

# Store in the variable named by $1 how to run a watcher in the background
# on this runtime: Claude Code's Bash tool option, or the shell tool's
# background or yield option elsewhere.
_hook_gh_background_advice() {
  local _bga_agent=''
  _hook_agent_name _bga_agent
  if [ "$_bga_agent" = claude ]; then
    printf -v "$1" '%s' 'Claude Code: run_in_background: true'
  else
    printf -v "$1" '%s' "your shell tool's background or yield option"
  fi
}

# Store in the variable named by $1 one `$2 <labels>` command per repository
# for the labels in $3: `git pr-watch` accepts only pull requests of the
# checkout it runs in, so labels from two repositories need two commands. One
# pass: each label's scope is computed once, and " <scope>=<index> " entries
# find its group by a builtin match.
_hook_gh_watch_commands() {
  local _wc_label _wc_scope _wc_index _wc_map=' ' _wc_out='' _wc_i
  local -a _wc_labels=() _wc_groups=()
  read -r -a _wc_labels <<<"$3"
  for _wc_label in ${_wc_labels[@]+"${_wc_labels[@]}"}; do
    _wc_scope=-
    _hook_gh_pr_key_scope "$_wc_label" >/dev/null && _wc_scope="$_HOOK_GH_PR_SCOPE"
    case "$_wc_map" in
      *" $_wc_scope="*)
        _wc_index="${_wc_map#* "$_wc_scope"=}"
        _wc_index="${_wc_index%% *}"
        _wc_groups[_wc_index]="${_wc_groups[_wc_index]} $_wc_label"
        ;;
      *)
        _wc_index="${#_wc_groups[@]}"
        _wc_groups[_wc_index]=" $_wc_label"
        _wc_map="$_wc_map$_wc_scope=$_wc_index "
        ;;
    esac
  done
  for ((_wc_i = 0; _wc_i < ${#_wc_groups[@]}; _wc_i++)); do
    _wc_out="$_wc_out${_wc_out:+ and }\`$2${_wc_groups[_wc_i]}\`"
  done
  [ "${#_wc_groups[@]}" -le 1 ] || _wc_out="$_wc_out, each from a checkout of its repository"
  printf -v "$1" '%s' "$_wc_out"
}

# Store in the variable named by $1 hint $2 with every `<labels>` token
# replaced by $3. Prefix and suffix expansion: a pattern replacement would
# treat `&` in the replacement specially in newer Bash.
_hook_gh_fill_hint() {
  local _fh_in="$2" _fh_out=''
  while :; do
    case "$_fh_in" in
      *'<labels>'*)
        _fh_out="$_fh_out${_fh_in%%<labels>*}$3"
        _fh_in="${_fh_in#*<labels>}"
        ;;
      *) break ;;
    esac
  done
  printf -v "$1" '%s' "$_fh_out$_fh_in"
}

# _hook_gh_checks_reminder [<watch-command>]
#
# Emit the general pull-request checks reminder, for output or commands that
# started checks nothing was recorded or re-armed for. It recommends
# AGENTGUARD_PR_WATCH_HINT when set; otherwise <watch-command> (default `git
# pr-watch --wait`) when it can run here (any given command, or `git-pr-watch`
# on PATH), with this runtime's background advice; otherwise `gh pr checks
# --watch`. A `<labels>` token in the hint becomes `<pr>`: no pull request
# is known here. Sets _HOOK_GH_WATCH_REMINDED. Callers de-duplicate.
_hook_gh_checks_reminder() {
  local watch="${1:-}" advice lead hint
  lead='PR checks gate: if this pushed or opened a GitHub pull request, it is not done or green until its checks pass on the pushed commit.'
  _HOOK_GH_WATCH_REMINDED=1
  if [ -n "${AGENTGUARD_PR_WATCH_HINT:-}" ]; then
    _hook_gh_fill_hint hint "$AGENTGUARD_PR_WATCH_HINT" '<pr>'
    _hook_remind "$lead $hint"
    return 0
  fi
  if [ -z "$watch" ] && command -v "$_HOOK_GH_PR_WATCH_ARGV" >/dev/null 2>&1; then
    watch='git pr-watch --wait'
  fi
  if [ -n "$watch" ]; then
    _hook_gh_background_advice advice
    _hook_remind "$lead Watch them in the background with \`$watch <pr>\` ($advice; never \`&\`, nohup, setsid, or disown) and report pending or failing checks instead of calling it green."
    return 0
  fi
  # shellcheck disable=SC2016 # Backticks are literal Markdown for the agent.
  _hook_remind "$lead"' Watch them in the background (`gh pr checks <pr> --repo <owner/repo> --watch --fail-fast`) and report pending or failing checks instead of calling it green.'
}

# _hook_gh_watch_pass <command-text> <output> <status|-> <background|-> [<watch-command>]
#
# The post-bash watch pass for one command, as post-bash runs it on the
# agent's own command and as a hook extension runs it on a command it
# unwrapped (a wrapper that runs `git push` for the agent):
#   <command-text>   the commands to judge, one or more lines of shell;
#   <output>         what they printed (stdout, or stdout and stderr); a push
#                    is also parsed with the hook payload's stderr, as
#                    post-bash does;
#   <status|->       their exit status, or `-` to read it from the payload;
#   <background|->   1 when the host ran the call in the background, 0 when
#                    not, or `-` to read it from the payload;
#   <watch-command>  the watcher to recommend, default `git pr-watch --wait`
#                    (a wrapper may name its own; recording still needs
#                    `git-pr-watch` on PATH).
# Fails, doing nothing, when the text runs no command that starts checks (a
# caller may then fall back to output evidence). Otherwise it succeeds, and
# for a successful command it records created pull requests, re-arms after
# `gh pr ready|reopen|update-branch` and pushes (a background call records
# nothing and a pushing one re-arms all), and reminds: after a record or
# re-arm, every time, with the watch commands; otherwise once per prompt per
# command text, with _hook_gh_checks_reminder, and not at all when this
# hook process already gave a PR checks reminder (_HOOK_GH_WATCH_REMINDED,
# say post-bash's own for a wrapped push's printed summary), so a wrapped
# command gets one general reminder, not two. AGENTGUARD_WATCH=0 turns
# recording and re-arming off; AGENTGUARD_PR_WATCH_HINT replaces the advice,
# its `<labels>` token filled in. Needs Bash 4 (the command classifier).
# Sets _HOOK_GH_WATCH_LABELS (the labels recorded or re-armed),
# _HOOK_GH_WATCH_PASS_REMINDED (1 when this call reminded, reset at entry),
# and _HOOK_GH_WATCH_REMINDED once the command's reminder is handled: given,
# or skipped as a repeat within the prompt.
_hook_gh_watch_pass() {
  local text="$1" output="$2" status="$3" background="$4" watch="${5:-}"
  local hint command advice key
  _HOOK_GH_W_LABELS=''
  _HOOK_GH_WATCH_LABELS=''
  _HOOK_GH_WATCH_PASS_REMINDED=''
  _hook_gh_watch_prefilter "$text" || return 1
  _hook_gh_classify "$text" || return 1
  [ "$status" != - ] || status=$(_hook_hm_tool_status)
  [ "$status" = 0 ] || return 0
  # Only a successful create, push, or gh re-arm feeds the obligations, and
  # push parsing runs only once this session recorded something to re-arm.
  if ! _hook_flag_disabled "${AGENTGUARD_WATCH:-}" &&
    { [ -n "$_HOOK_GH_W_CREATES" ] || [ "${#_HOOK_GH_W_TARGETS[@]}" -gt 0 ] ||
      { [ -n "$_HOOK_GH_W_PUSH" ] && [ -d "$_HOOK_STATE_DIR/watch" ]; }; } &&
    _hook_load_watch; then
    # A call the host runs in the background (Claude Code run_in_background,
    # a Muse background shell) reports before the command has done anything:
    # it records nothing (no URL yet), and a push re-arms every recorded pull
    # request rather than none, since a nuisance re-arm beats a missed one
    # and the producer's push-race guard covers an early check.
    if [ "$background" = - ]; then
      background=0
      _hook_tool_runs_in_background && background=1
    fi
    if [ "$background" = 1 ]; then
      _HOOK_GH_W_CREATES=''
      _HOOK_GH_W_TARGETS=()
    fi
    # The hint is free text the Stop hook repeats: how to start a watcher.
    # A `<labels>` token in it is replaced by the pull requests a message
    # names.
    hint="${AGENTGUARD_PR_WATCH_HINT:-Run \`${watch:-git pr-watch --wait} <labels>\` in the background (one run per repository, from its checkout) and act on its result when it exits.}"
    [ -z "$_HOOK_GH_W_CREATES" ] || _hook_gh_record_output "$output" "$hint"
    [ -d "$_HOOK_STATE_DIR/watch" ] || _HOOK_GH_W_TARGETS=()
    _hook_gh_rearm_targets
    if [ -n "$_HOOK_GH_W_PUSH" ] && [ -d "$_HOOK_STATE_DIR/watch" ]; then
      if [ "$background" = 1 ]; then
        _hook_gh_add_labels "$(_hook_watch_rearm "$_HOOK_GH_PR_TOOL_DIR" ALL)"
      else
        _hook_gh_rearm_pushed "$output"
      fi
    fi
  fi
  _HOOK_GH_WATCH_LABELS="${_HOOK_GH_W_LABELS# }"
  if [ -n "$_HOOK_GH_WATCH_LABELS" ]; then
    # Every record or re-arm is new work, so it always reminds, even when the
    # same command ran earlier in the prompt.
    _HOOK_GH_WATCH_REMINDED=1
    _HOOK_GH_WATCH_PASS_REMINDED=1
    if [ -n "${AGENTGUARD_PR_WATCH_HINT:-}" ]; then
      _hook_gh_fill_hint hint "$AGENTGUARD_PR_WATCH_HINT" "$_HOOK_GH_WATCH_LABELS"
      _hook_remind "PR checks gate: this started checks on $_HOOK_GH_WATCH_LABELS, which is not done or green until they pass on the pushed commit. $hint"
      return 0
    fi
    _hook_gh_watch_commands command "${watch:-git pr-watch --wait}" "$_HOOK_GH_WATCH_LABELS"
    _hook_gh_background_advice advice
    _hook_remind "PR checks gate: this started checks on $_HOOK_GH_WATCH_LABELS, which is not done or green until they pass on the pushed commit. Watch them in the background with $command ($advice; never \`&\`, nohup, setsid, or disown) and act on its result when it exits; report pending or failing checks instead of calling it green. Restart it after every exit until it reports done, unless it reports a stall (report that instead); a foreground run is killed at the tool timeout and silently stops watching."
    return 0
  fi
  # Otherwise once per prompt for the same command text: re-running it while
  # monitoring must not repeat the reminder.
  [ -z "${_HOOK_GH_WATCH_REMINDED:-}" ] || return 0
  key="pr-checks-$(printf '%s' "command:$text" | cksum | tr -d ' ')"
  if _hook_once_per_prompt "$key"; then
    _hook_gh_checks_reminder "$watch"
    _HOOK_GH_WATCH_PASS_REMINDED=1
  else
    # Already reminded for this command in the prompt: the output it printed
    # is handled too, so post-bash's output-evidence reminder must not stand
    # in for it with another watcher.
    _HOOK_GH_WATCH_REMINDED=1
  fi
  return 0
}
