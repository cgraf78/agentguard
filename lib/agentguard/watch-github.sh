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
