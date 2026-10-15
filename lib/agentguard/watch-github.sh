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

# Lowercase ASCII $2 into the variable named by $1 without a fork (Bash 3.2
# has no case-conversion expansion). Repository names are short.
_hook_gh_lower() {
  # Prefixed locals: $1 names a variable in the caller's scope.
  local _lc_in="$2" _lc_out='' _lc_c _lc_i _lc_upper='ABCDEFGHIJKLMNOPQRSTUVWXYZ'
  local _lc_lower='abcdefghijklmnopqrstuvwxyz' _lc_prefix
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
  if ! _hook_gh_name_ok "$owner" || ! _hook_gh_name_ok "$repo"; then
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
  if ! _hook_gh_name_ok "$owner" || ! _hook_gh_name_ok "$repo"; then
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
#   - a push command (one with a `push` word) that printed no `To` block and
#     no `Everything up-to-date` (a quiet or redirected push) re-arms ALL;
#     any other command (a stack tool with nothing to push) re-arms nothing;
#   - an up-to-date, rejected-only, or tag-only push re-arms nothing.
# The caller checks the push succeeded; a failed push never re-arms.
_hook_gh_push_scopes() {
  local output="$1" command="${2:-}" line url='' counted=0 blocks=0 uptodate=0
  local pushed='' recorded='' pair scope repo rscope
  _hook_gh_push_command_inert "$command" && return 0
  # Counted blocks collect as " <scope>/<repo> " pairs (neither holds `/`).
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line//$'\r'/}"
    case "$line" in
      'To '*)
        if [ "$counted" = 1 ] && _hook_gh_push_url_scope scope "$url"; then
          pushed="$pushed $scope/$_HOOK_GH_PUSH_REPO "
        fi
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
  if [ "$counted" = 1 ] && _hook_gh_push_url_scope scope "$url"; then
    pushed="$pushed $scope/$_HOOK_GH_PUSH_REPO "
  fi
  if [ "$blocks" = 0 ]; then
    [ "$uptodate" = 1 ] || [ "$_HOOK_GH_PUSH_WORD" = 0 ] || printf 'ALL\n'
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
