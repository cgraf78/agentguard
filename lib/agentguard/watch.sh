#!/usr/bin/env bash
# shellcheck shell=bash
# watch.sh — watch obligations for agent hooks.
#
# Some work an agent starts finishes long after the command that started it
# returns: pushing a branch or opening a pull request starts checks that run
# for minutes. A separate watcher process (a "producer", such as
# `git pr-watch --wait`) follows that work to the end and publishes small
# state files while it does. This engine records, per agent session, which
# keys (one per watched item) still need a watcher, and the Stop hook compares
# those records with the producer's state so an agent that ends its turn with
# nobody watching hears about it.
#
# The engine is producer-neutral: a tool is named by its state directory
# relative to a state root (for example `git-tools/pr-watch`), and keys and
# scopes are opaque strings it only ever compares whole. Recognizers that know
# a producer's vocabulary (watch-github.sh for pull requests) decide what to
# record. docs/watch-protocol.md documents the layout and every behavior here.
#
# Loaded lazily (_hook_load_watch), only once a cheap prefilter matched. It
# runs under Bash 3.2 (macOS /bin/bash runs the Stop hook), is `set -u` clean,
# never exits, and fails open: state it cannot trust or write means enforcing
# nothing, never a block. The Stop and collect paths use builtins only on
# Linux; macOS liveness checks pay one `ps` per candidate watcher.
#
# Session layout, under $_HOOK_STATE_DIR/watch/<tool-id>/ (tool-id is the
# tool dir with `/` replaced by `+`, which no name contains, so two tool dirs
# never share an id):
#   tool            three lines: tool dir, watcher argv basename, hint
#   keys/<key>      "<epoch> <scope>" then the label, one file per key
#   blocked/<key>   written when a Stop blocked for that key
#   forgotten/<key> a forgotten key's record (_hook_watch_forget); keys/<key>
#                   wins when both exist

# Keys from the latest collect that need a watcher, as "<tool-id> <key>".
_HOOK_WATCH_UNMET=()
# Producer tool dirs _hook_watch_roots accepted for the tool it was last asked
# about.
_HOOK_WATCH_DIRS=()
_HOOK_WATCH_ROOTS_FOR=''
_HOOK_WATCH_ROOTS_STATUS=1
# Fields of the last record each reader parsed.
_HOOK_WATCH_TOOL_DIR=''
_HOOK_WATCH_TOOL_ARGV=''
_HOOK_WATCH_TOOL_HINT=''
_HOOK_WATCH_KEY_EPOCH=''
_HOOK_WATCH_KEY_SCOPE=''
_HOOK_WATCH_KEY_LABEL=''
_HOOK_WATCH_DONE_EPOCH=0
_HOOK_WATCH_DONE_WORD=''
_HOOK_WATCH_DETACHED=0

# Whether $1 is safe as a single path component: keys, scopes, and tool-dir
# components reach paths, so `/`, `.`, `..`, and anything outside the
# producer contract's character set are refused. `~` marks producer temporary
# files and is never part of a name.
_hook_watch_name_ok() {
  case "${1:-}" in
    '' | . | .. | *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# Store the session id of tool dir $1 in the variable named by $2: the tool
# dir with `/` replaced by `+`. Names never contain `+`, so the mapping is
# one-to-one (with `_` instead, `a/b_c` and `a_b/c` would collide). Fails for
# an absolute, empty, or unsafe dir.
_hook_watch_tool_id() {
  # Prefixed locals: $2 names a variable in the caller's scope.
  local _ti_dir="${1:-}" _ti_rest _ti_component
  case "$_ti_dir" in
    '' | /* | */ | *//*) return 1 ;;
  esac
  _ti_rest="$_ti_dir"
  while [ -n "$_ti_rest" ]; do
    _ti_component="${_ti_rest%%/*}"
    _hook_watch_name_ok "$_ti_component" || return 1
    case "$_ti_rest" in
      */*) _ti_rest="${_ti_rest#*/}" ;;
      *) _ti_rest='' ;;
    esac
  done
  printf -v "$2" '%s' "${_ti_dir//\//+}"
}

# The session's watch dir; fails when no session state dir is known.
_hook_watch_session_dir() {
  [ -n "${_HOOK_STATE_DIR:-}" ] || return 1
  printf -v "$1" '%s' "$_HOOK_STATE_DIR/watch"
}

# Producer state is trusted only when every component from the state root to
# the file is a real directory or regular file owned by this user: a symlink
# or someone else's directory could forge "watched" or "done". Builtin tests
# only, no mode check (the producer creates its dirs private). A component
# that exists and fails makes the whole root unusable for the tool.
#
# Status of path $1 as a trusted directory: 0 trusted, 2 missing, 1 refused.
_hook_watch_dir_state() {
  if [ -L "$1" ]; then
    return 1
  elif [ -d "$1" ]; then
    [ -O "$1" ] || return 1
    return 0
  elif [ -e "$1" ]; then
    return 1
  fi
  return 2
}

# Whether path $1 is a trusted regular file.
_hook_watch_file_ok() {
  [ -f "$1" ] && [ ! -L "$1" ] && [ -O "$1" ]
}

# Resolve the producer dirs for tool dir $1 into _HOOK_WATCH_DIRS: the tool
# dir under each candidate state root that exists and passes the component
# checks. Candidate roots are an absolute XDG_STATE_HOME, then
# $HOME/.local/state (the producer writes to the first; the hook environment
# may not match the agent shell's, so both are read). A missing root or tool
# dir simply contributes nothing. Fails, so callers enforce nothing for the
# tool, when any component is refused or no candidate root exists at all: a
# refused root must never read as "no watcher". Cached per tool dir.
_hook_watch_roots() {
  local tool_dir="$1" root rest component path seen=' ' status any=0
  if [ "$_HOOK_WATCH_ROOTS_FOR" = "$tool_dir" ]; then
    return "$_HOOK_WATCH_ROOTS_STATUS"
  fi
  _HOOK_WATCH_DIRS=()
  _HOOK_WATCH_ROOTS_FOR="$tool_dir"
  _HOOK_WATCH_ROOTS_STATUS=1
  for root in "${XDG_STATE_HOME:-}" "${HOME:+$HOME/.local/state}"; do
    case "$root" in /*) ;; *) continue ;; esac
    case "$seen" in *" $root "*) continue ;; esac
    seen="$seen$root "
    any=1
    _hook_watch_dir_state "$root"
    status=$?
    [ "$status" -ne 1 ] || return 1
    [ "$status" -eq 0 ] || continue
    path="$root"
    rest="$tool_dir"
    while [ -n "$rest" ]; do
      component="${rest%%/*}"
      case "$rest" in
        */*) rest="${rest#*/}" ;;
        *) rest='' ;;
      esac
      path="$path/$component"
      _hook_watch_dir_state "$path"
      status=$?
      [ "$status" -ne 1 ] || return 1
      [ "$status" -eq 0 ] || break
    done
    [ "$status" -eq 0 ] || continue
    for component in watchers 'done' exited; do
      _hook_watch_dir_state "$path/$component"
      [ "$?" -ne 1 ] || return 1
    done
    _HOOK_WATCH_DIRS[${#_HOOK_WATCH_DIRS[@]}]="$path"
  done
  [ "$any" = 1 ] || return 1
  _HOOK_WATCH_ROOTS_STATUS=0
  return 0
}

# Whether process $1 is alive and runs a program whose basename is $2 as its
# argv[0] or argv[1] (a script may run as `bash /path/<name> ...`). A pid in a
# watcher file can be reused after a crash, so liveness alone is not enough.
# Linux reads argv from /proc with builtins; elsewhere `ps` prints the joined
# command line, matched so a path containing spaces still works. Where a
# launcher repeats the interpreter, as Termux does
# (`bash /path/to/bash /path/<name>`), a first word whose basename the next
# word repeats is skipped (at most twice). Returns 0 when it runs the
# program, 1 when it does not, and 2 when that cannot be probed (no /proc,
# and no ps or one that cannot report a live process's command line), which
# callers treat as watched: enforcing nothing beats nagging about a watcher
# that may be alive.
_HOOK_WATCH_PROC=/proc
_hook_watch_pid_runs() {
  local pid="$1" name="$2" word i=0 command
  local -a words=()
  case "$pid" in
    '' | 0* | *[!0-9]*) return 1 ;;
  esac
  if [ -r "$_HOOK_WATCH_PROC/self/cmdline" ]; then
    [ -r "$_HOOK_WATCH_PROC/$pid/cmdline" ] || return 1
    {
      while [ "${#words[@]}" -lt 4 ] && IFS= read -r -d '' word; do
        # Basename stripping is quadratic in a word's length; no program
        # path is this long, so a longer word (a reused pid's argument)
        # simply never matches.
        [ "${#word}" -le 4096 ] || word=/
        words[${#words[@]}]="$word"
      done
    } 2>/dev/null <"$_HOOK_WATCH_PROC/$pid/cmdline" || return 1
    while [ "$i" -lt 2 ] && [ "${#words[@]}" -gt $((i + 1)) ] &&
      [ "${words[i]##*/}" = "${words[i + 1]##*/}" ]; do
      i=$((i + 1))
    done
    word="${words[i]:-}"
    [ "${word##*/}" != "$name" ] || return 0
    word="${words[i + 1]:-}"
    [ -n "$word" ] && [ "${word##*/}" = "$name" ]
    return
  fi
  # A dead pid is dead whatever else can be probed.
  kill -0 "$pid" 2>/dev/null || return 1
  command -v ps >/dev/null 2>&1 || return 2
  # The process is alive; a ps that cannot report its command line (BusyBox
  # has no -p) cannot tell it apart either, so that also fails open.
  command=$(ps -o command= -p "$pid" 2>/dev/null) || return 2
  [ -n "$command" ] || return 2
  case " $command " in
    *" $name "* | *"/$name "*) return 0 ;;
  esac
  return 1
}

# Whether a live watcher covers key $1 with scope $2 (`-` for none) in any
# accepted producer dir: watchers/<key>.<pid> names exactly that key, and a
# pending file (written while a watcher still resolves its targets) covers
# every key (pending.<pid>) or every key of its scope (pending.<scope>.<pid>;
# the pid is the last `.` field, and a scope may itself contain `.`). $3 is
# the watcher's argv basename.
_hook_watch_watched() {
  local key="$1" scope="$2" argv="$3" dir file name pid rest
  for dir in ${_HOOK_WATCH_DIRS[@]+"${_HOOK_WATCH_DIRS[@]}"}; do
    for file in "$dir/watchers/$key".* "$dir/watchers/pending".*; do
      name="${file##*/}"
      case "$name" in *'~'*) continue ;; esac
      pid="${name##*.}"
      rest="${name%.*}"
      if [ "$rest" = "$key" ] || [ "$rest" = pending ] ||
        { [ "$scope" != - ] && [ "$rest" = "pending.$scope" ]; }; then
        _hook_watch_file_ok "$file" || continue
        _hook_watch_pid_runs "$pid" "$argv"
        # 2: liveness cannot be probed; count the watcher (fail open).
        [ "$?" = 1 ] || return 0
      fi
    done
  done
  return 1
}

# Store in the variable named by $1 the epoch field $2 of a state record:
# 0 for `-`, a missing field, or anything not a plain number (all of which
# count as before any event), without leading zeros (octal in arithmetic).
_hook_watch_epoch() {
  local _ep_value="$2"
  case "$_ep_value" in
    '' | *[!0-9]*) _ep_value=0 ;;
  esac
  _ep_value="${_ep_value#"${_ep_value%%[!0]*}"}"
  _ep_value="${_ep_value:-0}"
  [ "${#_ep_value}" -le 15 ] || _ep_value=0
  printf -v "$1" '%s' "$_ep_value"
}

# Read the newest done/<key> record across the accepted producer dirs into
# _HOOK_WATCH_DONE_EPOCH and _HOOK_WATCH_DONE_WORD. The content is
# "<commit> <word> <epoch>"; fails when no readable record exists.
_hook_watch_done() {
  local key="$1" dir file word epoch found=1
  _HOOK_WATCH_DONE_EPOCH=0
  _HOOK_WATCH_DONE_WORD=''
  for dir in ${_HOOK_WATCH_DIRS[@]+"${_HOOK_WATCH_DIRS[@]}"}; do
    file="$dir/done/$key"
    _hook_watch_file_ok "$file" || continue
    word='' epoch=''
    read -r _ word epoch 2>/dev/null <"$file" || [ -n "$word" ] || continue
    _hook_watch_epoch epoch "$epoch"
    if [ "$found" = 1 ] || [ "$epoch" -gt "$_HOOK_WATCH_DONE_EPOCH" ]; then
      _HOOK_WATCH_DONE_EPOCH="$epoch"
      _HOOK_WATCH_DONE_WORD="$word"
      found=0
    fi
  done
  return "$found"
}

# Whether any accepted producer dir holds an exited/<key> record whose state
# field is `done` (the run's last result was green or merged) and whose
# epoch, when the check behind that result started, is strictly newer than
# $2. The content is "<status> <state> <reason> <epoch>"; red, needs-action,
# stalled, pending, and cut-short (`-`) exits never count. The file's mtime
# plays no part here (see _hook_watch_claim_block for that).
_hook_watch_exited_done() {
  local key="$1" since="$2" dir file state epoch
  for dir in ${_HOOK_WATCH_DIRS[@]+"${_HOOK_WATCH_DIRS[@]}"}; do
    file="$dir/exited/$key"
    _hook_watch_file_ok "$file" || continue
    state='' epoch=''
    read -r _ state _ epoch _ 2>/dev/null <"$file" || [ -n "$epoch" ] || continue
    [ "$state" = 'done' ] || continue
    _hook_watch_epoch epoch "$epoch"
    [ "$epoch" -le "$since" ] || return 0
  done
  return 1
}

# Whether key $1's newest done record says the item can no longer change
# (merged or closed); scope and ALL re-arms skip such keys.
_hook_watch_terminal() {
  _hook_watch_done "$1" || return 1
  case "$_HOOK_WATCH_DONE_WORD" in
    merged | closed) return 0 ;;
  esac
  return 1
}

# Read session key file $1 into _HOOK_WATCH_KEY_EPOCH, _HOOK_WATCH_KEY_SCOPE,
# and _HOOK_WATCH_KEY_LABEL. Fails on a missing or malformed record.
_hook_watch_read_key() {
  local epoch='' scope='' label=''
  [ -f "$1" ] || return 1
  {
    read -r epoch scope || true
    IFS= read -r label || true
  } 2>/dev/null <"$1" || return 1
  case "$epoch" in
    '' | 0* | *[!0-9]*) return 1 ;;
  esac
  [ "${#epoch}" -le 15 ] || return 1
  [ "$scope" = - ] || _hook_watch_name_ok "$scope" || return 1
  _HOOK_WATCH_KEY_EPOCH="$epoch"
  _HOOK_WATCH_KEY_SCOPE="$scope"
  _HOOK_WATCH_KEY_LABEL="${label:-${1##*/}}"
}

# Read session tool file $1 into _HOOK_WATCH_TOOL_DIR, _HOOK_WATCH_TOOL_ARGV,
# and _HOOK_WATCH_TOOL_HINT. Fails when it is missing or names an unsafe dir.
_hook_watch_read_tool() {
  local dir='' argv='' hint='' id
  [ -f "$1" ] || return 1
  {
    IFS= read -r dir || true
    IFS= read -r argv || true
    IFS= read -r hint || true
  } 2>/dev/null <"$1" || return 1
  _hook_watch_tool_id "$dir" id || return 1
  _hook_watch_name_ok "$argv" || return 1
  _HOOK_WATCH_TOOL_DIR="$dir"
  _HOOK_WATCH_TOOL_ARGV="$argv"
  _HOOK_WATCH_TOOL_HINT="$hint"
}

# Write key $2's record in session tool dir $1 with epoch $3, scope $4, and
# label $5.
_hook_watch_write_key() {
  [ -d "$1/keys" ] || _hook_mkstate "$1/keys" || return 1
  _hook_write_atomic "$1/keys/$2" "$3 $4"$'\n'"$5"
}

# --- Public API ---

# _hook_watch_record <tool-dir> <key> <scope|-> <argv-basename> <label> <hint>
#
# Record that this session started work on <key> that a watcher should
# follow: a new submit, superseding any earlier one of the same key. <scope>
# groups keys for scoped pending files and re-arms (`-` for none),
# <argv-basename> names the watcher program for liveness checks, <label> is
# how messages name the key, and <hint> is free text telling the agent how to
# start a watcher. The tool's argv basename and hint are per tool: the latest
# record wins. Best effort: an unwritable state dir only loses enforcement.
_hook_watch_record() {
  local tool_dir="$1" key="$2" scope="$3" argv="$4" label="$5" hint="$6"
  local id base now
  _hook_watch_tool_id "$tool_dir" id || return 1
  _hook_watch_name_ok "$key" || return 1
  [ "$scope" = - ] || _hook_watch_name_ok "$scope" || return 1
  _hook_watch_name_ok "$argv" || return 1
  _hook_watch_session_dir base || return 1
  _hook_now now || return 1
  base="$base/$id"
  [ -d "$base" ] || _hook_mkstate "$base" || return 1
  # One line each: a newline would shift every later field.
  label="${label//$'\n'/ }"
  hint="${hint//$'\n'/ }"
  # The tool file rarely changes; rewriting it only when it does saves an mv.
  if ! _hook_watch_read_tool "$base/tool" || [ "$_HOOK_WATCH_TOOL_DIR" != "$tool_dir" ] ||
    [ "$_HOOK_WATCH_TOOL_ARGV" != "$argv" ] || [ "$_HOOK_WATCH_TOOL_HINT" != "$hint" ]; then
    _hook_write_atomic "$base/tool" "$tool_dir"$'\n'"$argv"$'\n'"$hint" || return 1
  fi
  _hook_watch_write_key "$base" "$key" "$now" "$scope" "$label"
}

# _hook_watch_forget <tool-dir> <key>
#
# Stop requiring a watcher for one recorded key because its item ended with
# nobody watching (a pull request merged or closed). The record moves to
# forgotten/<key>, which only _hook_watch_rearm_key and `_hook_watch_list
# <tool-dir> forgotten` read, so a later reopen can revive it while Stop,
# collect, and scope or ALL re-arms (a push) ignore it; the key's Stop block
# marker goes with it. Sets _HOOK_WATCH_KEY_LABEL and succeeds when it
# forgot. A key this session never recorded, or a move that fails, is left
# as it was: a key that stays only costs a reminder, a lost one a missed
# watch. A re-arm racing the move can write keys/<key> again; keys/ then
# wins, which errs toward the reminder.
_hook_watch_forget() {
  local tool_dir="$1" key="$2" id base
  _hook_watch_tool_id "$tool_dir" id || return 1
  _hook_watch_name_ok "$key" || return 1
  _hook_watch_session_dir base || return 1
  base="$base/$id"
  _hook_watch_read_key "$base/keys/$key" || return 1
  [ -d "$base/forgotten" ] || _hook_mkstate "$base/forgotten" || return 1
  mv -f -- "$base/keys/$key" "$base/forgotten/$key" 2>/dev/null || return 1
  # A builtin test first: most keys never blocked, so this rarely forks.
  [ ! -e "$base/blocked/$key" ] || rm -f -- "$base/blocked/$key" 2>/dev/null
  return 0
}

# _hook_watch_rearm <tool-dir> <scope>... | ALL
#
# Re-open this session's recorded keys of the tool whose scope is one of the
# given scopes (or every key, for ALL), because new work (a push) restarted
# what their watchers follow. Keys whose producer recorded them merged or
# closed are skipped: only _hook_watch_rearm_key revives those. Prints the
# label of each key it re-armed, one per line.
_hook_watch_rearm() {
  local tool_dir="$1" id base file key scope now all=0 match
  shift
  _hook_watch_tool_id "$tool_dir" id || return 1
  _hook_watch_session_dir base || return 1
  base="$base/$id"
  [ -d "$base/keys" ] || return 0
  for scope in "$@"; do
    [ "$scope" != ALL ] || all=1
  done
  _hook_now now || return 1
  # Without trusted producer state a terminal key cannot be told apart, so
  # every matching key re-arms; enforcement itself still fails open later.
  _hook_watch_roots "$tool_dir" || _HOOK_WATCH_DIRS=()
  for file in "$base/keys"/*; do
    key="${file##*/}"
    _hook_watch_name_ok "$key" || continue
    _hook_watch_read_key "$file" || continue
    if [ "$all" = 0 ]; then
      match=0
      for scope in "$@"; do
        [ "$scope" != "$_HOOK_WATCH_KEY_SCOPE" ] || match=1
      done
      [ "$match" = 1 ] || continue
    fi
    _hook_watch_terminal "$key" && continue
    _hook_watch_write_key "$base" "$key" "$now" "$_HOOK_WATCH_KEY_SCOPE" \
      "$_HOOK_WATCH_KEY_LABEL" &&
      printf '%s\n' "$_HOOK_WATCH_KEY_LABEL"
  done
  return 0
}

# _hook_watch_rearm_key <tool-dir> <key>
#
# Re-open one recorded key even when its producer recorded it merged or
# closed, or this session forgot it (_hook_watch_forget): a reopened pull
# request, say. Prints its label when it re-armed; a key this session never
# recorded is left alone. A revived key's record is written to keys/ before
# its forgotten copy goes, so an interruption leaves both and keys/ wins.
_hook_watch_rearm_key() {
  local tool_dir="$1" key="$2" id base now revive=0
  _hook_watch_tool_id "$tool_dir" id || return 1
  _hook_watch_name_ok "$key" || return 1
  _hook_watch_session_dir base || return 1
  base="$base/$id"
  if ! _hook_watch_read_key "$base/keys/$key"; then
    _hook_watch_read_key "$base/forgotten/$key" || return 0
    revive=1
  fi
  _hook_now now || return 1
  _hook_watch_write_key "$base" "$key" "$now" "$_HOOK_WATCH_KEY_SCOPE" \
    "$_HOOK_WATCH_KEY_LABEL" || return 0
  [ "$revive" = 0 ] || rm -f -- "$base/forgotten/$key" 2>/dev/null
  printf '%s\n' "$_HOOK_WATCH_KEY_LABEL"
  return 0
}

# _hook_watch_list <tool-dir> [forgotten]
#
# Print one "<key> <scope> <terminal|open>" line per key this session
# recorded for the tool, uninterpreted. Recognizers use it to map their own
# vocabulary (a repository, a number) onto recorded keys. With `forgotten`,
# also print "<key> <scope> forgotten" per forgotten key (see
# _hook_watch_forget) not recorded again.
_hook_watch_list() {
  local tool_dir="$1" id base file key state
  _hook_watch_tool_id "$tool_dir" id || return 1
  _hook_watch_session_dir base || return 1
  base="$base/$id"
  if [ -d "$base/keys" ]; then
    _hook_watch_roots "$tool_dir" || _HOOK_WATCH_DIRS=()
    for file in "$base/keys"/*; do
      key="${file##*/}"
      _hook_watch_name_ok "$key" || continue
      _hook_watch_read_key "$file" || continue
      state=open
      _hook_watch_terminal "$key" && state=terminal
      printf '%s %s %s\n' "$key" "$_HOOK_WATCH_KEY_SCOPE" "$state"
    done
  fi
  [ "${2:-}" = forgotten ] && [ -d "$base/forgotten" ] || return 0
  for file in "$base/forgotten"/*; do
    key="${file##*/}"
    _hook_watch_name_ok "$key" || continue
    [ ! -e "$base/keys/$key" ] || continue
    _hook_watch_read_key "$file" || continue
    printf '%s %s forgotten\n' "$key" "$_HOOK_WATCH_KEY_SCOPE"
  done
  return 0
}

# Whether recorded key $1 (scope $2, submitted or re-armed at epoch $3) is
# satisfied: a live watcher or matching pending file; a done record whose
# check started after the submit; or an exited record of a run whose last
# result was green or merged (state `done`) from a check that started after
# it. The exited case covers a multi-pull-request run whose done record
# predates a later push but which went on judging the pull request. A red,
# needs-action, stalled, or cut-short exit does not satisfy: the agent must
# act on it and watch again (see _hook_watch_claim_block). A check that
# started in the same second may not have seen the submit, so only strictly
# newer epochs count. Per the producer contract, watchers/ is listed before
# the records and once more when nothing showed, because one listing can
# miss a watcher file while another replaces it.
_hook_watch_satisfied() {
  local key="$1" scope="$2" epoch="$3" argv="$4"
  _hook_watch_watched "$key" "$scope" "$argv" && return 0
  if _hook_watch_done "$key" && [ "$_HOOK_WATCH_DONE_EPOCH" -gt "$epoch" ]; then
    return 0
  fi
  _hook_watch_exited_done "$key" "$epoch" && return 0
  _hook_watch_watched "$key" "$scope" "$argv"
}

# _hook_watch_collect
#
# Fill _HOOK_WATCH_UNMET with "<tool-id> <key>" for every key this session
# recorded that is not satisfied (see _hook_watch_satisfied). A tool
# whose producer state cannot be trusted (or whose session metadata is
# unreadable) contributes nothing. File tests and reads only: no network.
_hook_watch_collect() {
  local base tool_base id file key
  _HOOK_WATCH_UNMET=()
  _hook_watch_session_dir base || return 0
  for tool_base in "$base"/*; do
    [ -d "$tool_base/keys" ] || continue
    id="${tool_base##*/}"
    _hook_watch_read_tool "$tool_base/tool" || continue
    _hook_watch_roots "$_HOOK_WATCH_TOOL_DIR" || continue
    for file in "$tool_base/keys"/*; do
      key="${file##*/}"
      _hook_watch_name_ok "$key" || continue
      _hook_watch_read_key "$file" || continue
      _hook_watch_satisfied "$key" "$_HOOK_WATCH_KEY_SCOPE" \
        "$_HOOK_WATCH_KEY_EPOCH" "$_HOOK_WATCH_TOOL_ARGV" && continue
      _HOOK_WATCH_UNMET[${#_HOOK_WATCH_UNMET[@]}]="$id $key"
    done
  done
  return 0
}

# _hook_watch_claim_block <tool-dir> <key>
#
# Claim the one Stop block a key gets per submit or watcher exit, writing
# blocked/<key> (its mtime is the block's time). A block is armed when none
# was recorded yet, when the key was recorded or re-armed (keys/<key>) since
# the last one, or when a watcher run for it ended since then (the
# producer's exited/<key> is newer than the marker) without reporting a
# stall: a red, needs-action, or killed run leaves the agent something to
# fix and watch again, while a stall the watcher reported (exit status 8,
# state `stall`) waits on something outside the pull request, which the
# agent should report rather than restart a watcher for. A run killed while
# the pull request was last judged stalled (`143 stall ...`) still re-arms. Every re-arm
# needs new work or a new watcher run in between, so blocks stay bounded and
# a Stop can always end the turn. Bash 3.2 compares whole-second mtimes, so
# an event in the block's own second does not arm another (fails toward no
# block). The claim holds only once the marker is written: an unwritable
# state dir degrades to a reminder, never to a block on every Stop.
_hook_watch_claim_block() {
  local tool_dir="$1" key="$2" id base marker dir status state armed=0
  _hook_watch_tool_id "$tool_dir" id || return 1
  _hook_watch_name_ok "$key" || return 1
  _hook_watch_session_dir base || return 1
  base="$base/$id"
  marker="$base/blocked/$key"
  if [ ! -e "$marker" ] || [ "$base/keys/$key" -nt "$marker" ]; then
    armed=1
  elif _hook_watch_roots "$tool_dir"; then
    for dir in ${_HOOK_WATCH_DIRS[@]+"${_HOOK_WATCH_DIRS[@]}"}; do
      _hook_watch_file_ok "$dir/exited/$key" || continue
      [ "$dir/exited/$key" -nt "$marker" ] || continue
      status='' state=''
      read -r status state _ 2>/dev/null <"$dir/exited/$key" || [ -n "$state" ] || continue
      [ "$status $state" = "8 stall" ] || armed=1
    done
  fi
  [ "$armed" = 1 ] || return 1
  [ -d "$base/blocked" ] || _hook_mkstate "$base/blocked" || return 1
  # Write content, not just truncate: O_TRUNC on an empty file need not bump
  # its mtime, which is what the arming comparison reads.
  printf '%s\n' "$$" 2>/dev/null >"$marker"
}

# Store in the variable named by $1 the current tool's hint with its first
# `<labels>` token replaced by labels $2 (space-led). Plain prefix and suffix
# expansion: a pattern replacement would treat `&` in a label specially in
# newer Bash.
_hook_watch_hint() {
  local _hi_hint="$_HOOK_WATCH_TOOL_HINT"
  case "$_hi_hint" in
    *'<labels>'*) _hi_hint="${_hi_hint%%<labels>*}${2# }${_hi_hint#*<labels>}" ;;
  esac
  printf -v "$1" '%s' "$_hi_hint"
}

# _hook_watch_stop [<tool-dir>=<VARIABLE>]...
#
# The Stop hook's watch pass. Call it only for a foreground Stop. Reminds on
# stderr once per prompt per key and submit; with AGENTGUARD_WATCH_BLOCK=1 on
# Claude, blocks instead, once per submit or non-stall watcher exit (see
# _hook_watch_claim_block). A `<labels>` token in a tool's hint is replaced
# by the labels the message names. Each argument names the hook-environment variable
# that turns a tool's producer state off when set to the literal `0`; such a
# tool gets one note saying so instead of reminders it could never satisfy.
_hook_watch_stop() {
  local entry id key tool_base pair var block=0 agent message remind='' blocks=''
  local current='' remind_labels='' block_labels='' off='' skip=0 hint=''
  _hook_watch_collect
  [ "${#_HOOK_WATCH_UNMET[@]}" -gt 0 ] || return 0
  if _hook_flag_enabled "${AGENTGUARD_WATCH_BLOCK:-}"; then
    _hook_agent_name agent
    [ "$agent" != claude ] || block=1
  fi
  # Entries arrive grouped by tool; flush one message per tool.
  # The sentinel's id `/` can never be a tool id (ids hold no `/`).
  for entry in ${_HOOK_WATCH_UNMET[@]+"${_HOOK_WATCH_UNMET[@]}"} '/ /'; do
    id="${entry%% *}"
    key="${entry#* }"
    if [ "$id" != "$current" ] && [ -n "$current" ]; then
      if [ -n "$off" ]; then
        if _hook_once_per_prompt "watch-off-$current"; then
          remind="$remind${remind:+ }$off=0 in the hook environment turns $_HOOK_WATCH_TOOL_ARGV state files off, so AgentGuard cannot tell whether$remind_labels is watched. Unset it to restore this check."
        fi
      else
        if [ -n "$remind_labels" ]; then
          _hook_watch_hint hint "$remind_labels"
          remind="$remind${remind:+ }Not watched since the last push or submit:$remind_labels. $hint"
        fi
        if [ -n "$block_labels" ]; then
          _hook_watch_hint hint "$block_labels"
          blocks="$blocks${blocks:+ }No running \`$_HOOK_WATCH_TOOL_ARGV\` and no green, merged, or closed result since the latest push or submit for$block_labels, so nothing will report its outcome. $hint On Claude Code, use run_in_background: true. If the last watcher reported a stall, report that to the user instead of restarting it. If it reported failing checks, fix and push, then watch again. If monitoring should stop, tell the user explicitly why (for example, a still-running subagent that pushed it owns the watch)."
        fi
      fi
      remind_labels='' block_labels=''
    fi
    [ "$id" != / ] || break
    tool_base="$_HOOK_STATE_DIR/watch/$id"
    if [ "$id" != "$current" ]; then
      current="$id"
      off=''
      skip=0
      _hook_watch_read_tool "$tool_base/tool" || skip=1
      for pair in "$@"; do
        [ "${pair%%=*}" = "$_HOOK_WATCH_TOOL_DIR" ] || continue
        var="${pair#*=}"
        case "$var" in
          [A-Za-z_]*) ;;
          *) continue ;;
        esac
        case "$var" in *[!A-Za-z0-9_]*) continue ;; esac
        [ "${!var-}" != 0 ] || off="$var"
      done
    fi
    [ "$skip" = 0 ] || continue
    _hook_watch_read_key "$tool_base/keys/$key" || continue
    if [ -n "$off" ]; then
      remind_labels="$remind_labels $_HOOK_WATCH_KEY_LABEL"
      continue
    fi
    # A block when armed; otherwise one reminder per prompt per key and
    # submit. The prompt marker is claimed even for a block, so the Stop
    # that follows a block in the same prompt does not remind again; a
    # watcher exit can re-arm a block within the prompt without changing the
    # key's epoch, so an existing marker does not rule a block out.
    if _hook_once_per_prompt "watch-$id-$key-$_HOOK_WATCH_KEY_EPOCH"; then
      if [ "$block" = 1 ] && _hook_watch_claim_block "$_HOOK_WATCH_TOOL_DIR" "$key"; then
        block_labels="$block_labels $_HOOK_WATCH_KEY_LABEL"
      else
        remind_labels="$remind_labels $_HOOK_WATCH_KEY_LABEL"
      fi
    elif [ "$block" = 1 ] && _hook_watch_claim_block "$_HOOK_WATCH_TOOL_DIR" "$key"; then
      block_labels="$block_labels $_HOOK_WATCH_KEY_LABEL"
    fi
  done
  if [ -n "$blocks" ]; then
    _hook_block "$blocks This blocks once per push, submit, or watcher exit (a stall never re-arms it); later Stops do not."
  fi
  if [ -n "$remind" ]; then
    # stderr only: a Stop response's context is not delivered to the model
    # the way a tool hook's is, and some hosts treat it as keep-working
    # feedback. The post-bash reminder is the model-visible one.
    message="$remind"
    _hook_telemetry_note _HOOK_TELEMETRY_REMINDERS "$message"
    printf 'REMINDER: %s\n' "$message" >&2
  fi
  return 0
}

# --- Watcher launch detection (pre-bash) ---
#
# A watcher only helps while someone receives its result. A foreground Bash
# call is killed at the host's tool timeout long before a long wait ends, and
# a detached one (`&`, nohup, setsid, disown) keeps running with nobody
# receiving its exit status, while its watcher file still satisfies the Stop
# check. These helpers need the command classifier (Bash 4), so only pre-bash
# calls them. The command is a parameter: a word (`tool`), or a word plus a
# subcommand (`git pr-watch`, which also matches git's dashed `git-pr-watch`
# form).

# Store shell text $1 in the variable named by $2 with the operators `&`,
# `;`, `|`, and newlines inside quoted spans replaced by `_`, quotes and
# backslash escapes removed, and `#` comments dropped, so a lone `&` inside an
# argument (`sed 's/&/and/'`, a URL) does not read as backgrounding while a
# quoted command word stays visible. It works in chunks between special
# characters: Bash's per-character substring and append are quadratic, and
# pre-bash must finish within its classification deadline on a long line.
_hook_watch_unquoted() {
  # Prefixed locals: $2 names a variable in the caller's scope.
  local _uq_rest="$1" _uq_out='' _uq_chunk _uq_c='' _uq_prev=' ' _uq_q=''
  while [ -n "$_uq_rest" ]; do
    if [ -z "$_uq_q" ]; then
      _uq_chunk="${_uq_rest%%[\'\"\\#]*}"
      _uq_out="$_uq_out$_uq_chunk"
      _uq_rest="${_uq_rest:${#_uq_chunk}}"
      [ -z "$_uq_chunk" ] || _uq_prev="${_uq_chunk:${#_uq_chunk}-1:1}"
      [ -n "$_uq_rest" ] || break
      _uq_c="${_uq_rest:0:1}"
      _uq_rest="${_uq_rest:1}"
      case "$_uq_c" in
        "'" | '"') _uq_q="$_uq_c" ;;
        "\\") _uq_rest="${_uq_rest:1}" ;;
        '#')
          case "$_uq_prev" in
            [[:space:]] | ';' | '&' | '|' | '(')
              # A comment runs to the end of its line.
              case "$_uq_rest" in
                *$'\n'*)
                  _uq_rest="${_uq_rest#*$'\n'}"
                  _uq_out="$_uq_out"$'\n'
                  ;;
                *) _uq_rest='' ;;
              esac
              ;;
            *) _uq_out="$_uq_out#" ;;
          esac
          ;;
      esac
    else
      if [ "$_uq_q" = "'" ]; then
        _uq_chunk="${_uq_rest%%\'*}"
      else
        _uq_chunk="${_uq_rest%%[\"\\]*}"
      fi
      _uq_rest="${_uq_rest:${#_uq_chunk}}"
      _uq_chunk="${_uq_chunk//[&;|]/_}"
      _uq_out="$_uq_out${_uq_chunk//$'\n'/_}"
      [ -n "$_uq_rest" ] || break
      _uq_c="${_uq_rest:0:1}"
      _uq_rest="${_uq_rest:1}"
      if [ "$_uq_c" = "\\" ]; then
        _uq_rest="${_uq_rest:1}"
      else
        _uq_q=''
      fi
    fi
    _uq_prev="$_uq_c"
  done
  printf -v "$2" '%s' "$_uq_out"
}

# Whether the hook's command backgrounds a command named by $1 with a lone
# `&`. Executable fragments drop that operator, so this reads the masked
# text. Only a command-word occurrence counts (one that starts at a word,
# `/`, or `-` boundary and ends at whitespace: `pr-watch.log` is a file);
# when $1 is a subcommand of command $2, it must also follow `$2-` or share
# its simple command with a `$2` word, so `echo pr-watch &` does not count.
# A lone `&` anywhere in the rest of its and-or list (up to `;` or the line's
# end, ignoring `&&`, `>&`, `&>`, `<&`, and `|&`) backgrounds the whole list.
# Lines without both the name and an `&` are skipped unmasked, and so is a
# line over 8 KiB or one past a 16 KiB budget for the whole command: masking
# costs a copy of the rest of the line per quote or backslash, pre-bash must
# stay inside its classification deadline, and reading such a line raw could
# turn a quoted `&` into a false block. Skipping fails open (nohup, setsid,
# and disown are still seen). An `&` inside `bash -c '...'`, `$(...)`,
# `{ ...; } &`, or ANSI-C quoting is not modeled.
_hook_watch_text_detaches() {
  # A C locale: the scan looks only at ASCII operators, and multibyte
  # matching in a UTF-8 caller locale roughly doubles its cost. Restoring an
  # uninstalled caller locale on return prints a setlocale warning, so the
  # caller sends this function's stderr to /dev/null.
  local needle="$1" command="${2:-}" line rest before simple seg budget=16384 LC_ALL=C
  while IFS= read -r line; do
    case "$line" in *"$needle"*) ;; *) continue ;; esac
    case "$line" in *'&'*) ;; *) continue ;; esac
    # A subcommand needs its command on the same line; checked raw, before
    # paying for the mask.
    if [ -n "$command" ]; then
      case "$line" in *"$command"*) ;; *) continue ;; esac
    fi
    [ "${#line}" -le 8192 ] && [ "${#line}" -le "$budget" ] || continue
    budget=$((budget - ${#line}))
    _hook_watch_unquoted "$line" rest
    while :; do
      case "$rest" in *"$needle"*) ;; *) break ;; esac
      before="${rest%%"$needle"*}"
      rest="${rest:${#before}+${#needle}}"
      case "$rest" in '' | [[:space:]]*) ;; *) continue ;; esac
      case "$before" in '' | *[[:space:]/\(-]) ;; *) continue ;; esac
      if [ -n "$command" ]; then
        case "$before" in
          *"$command-") ;;
          *)
            simple="${before##*[;&|(]}"
            case " $simple" in *[[:space:]/]"$command "*) ;; *) continue ;; esac
            ;;
        esac
      fi
      seg="${rest%%;*}"
      seg="${seg//'&&'/}"
      seg="${seg//'>&'/}"
      seg="${seg//'&>'/}"
      seg="${seg//'<&'/}"
      seg="${seg//'|&'/}"
      case "$seg" in *'&'*) return 0 ;; esac
    done
  done <<<"${AGENTGUARD_CMD_TRIMMED:-}"
  return 1
}

# Find where command $2 (with subcommand $3, if any) starts in fragment $1,
# whose words are in _HOOK_WATCH_WORDS. Stores the index of the command word
# (or of the subcommand) in _HOOK_WATCH_START. Only the fragment's command
# word counts, so `echo git pr-watch --wait` is not a launch: the classifier
# resolves it behind its usual wrappers (env, nohup, timeout, sudo), and this
# also skips the wrappers it keeps as the command word (setsid, stdbuf,
# caffeinate) and accepts an interpreter running the command's script
# (`bash /path/git-pr-watch`).
_hook_watch_command_start() {
  local fragment="$1" command="$2" sub="${3:-}" k n word
  n="${#_HOOK_WATCH_WORDS[@]}"
  if [ -n "$sub" ] && [ "$command" = git ] && _git_subcommand_index "$fragment" "$sub" k; then
    _HOOK_WATCH_START="$k"
    return 0
  fi
  _fragment_command_index "$fragment" k || return 1
  while [ "$k" -lt "$n" ]; do
    _clean_command_word "${_HOOK_WATCH_WORDS[k]}" word
    case "${word##*/}" in
      setsid | nohup)
        k=$((k + 1))
        while [ "$k" -lt "$n" ]; do
          _clean_command_word "${_HOOK_WATCH_WORDS[k]}" word
          case "$word" in
            -*) k=$((k + 1)) ;;
            *) break ;;
          esac
        done
        ;;
      caffeinate)
        k=$((k + 1))
        while [ "$k" -lt "$n" ]; do
          _clean_command_word "${_HOOK_WATCH_WORDS[k]}" word
          case "$word" in
            -w | -t) k=$((k + 2)) ;;
            -*) k=$((k + 1)) ;;
            *) break ;;
          esac
        done
        ;;
      bash | sh | zsh | dash)
        # An explicit interpreter running the command's script. A `-c`
        # payload is a nested command the classifier already splits out.
        k=$((k + 1))
        while [ "$k" -lt "$n" ]; do
          _clean_command_word "${_HOOK_WATCH_WORDS[k]}" word
          case "$word" in
            -c | -*c*) return 1 ;;
            -o | +o) k=$((k + 2)) ;;
            -* | +*) k=$((k + 1)) ;;
            *) break ;;
          esac
        done
        break
        ;;
      stdbuf)
        k=$((k + 1))
        while [ "$k" -lt "$n" ]; do
          _clean_command_word "${_HOOK_WATCH_WORDS[k]}" word
          case "$word" in
            -i | -o | -e) k=$((k + 2)) ;;
            -*) k=$((k + 1)) ;;
            *) break ;;
          esac
        done
        ;;
      *) break ;;
    esac
  done
  [ "$k" -lt "$n" ] || return 1
  _clean_command_word "${_HOOK_WATCH_WORDS[k]}" word
  word="${word##*/}"
  if [ -z "$sub" ] || [ "$word" = "$command-$sub" ]; then
    [ "$word" = "$command" ] || [ "$word" = "$command-$sub" ] || return 1
    _HOOK_WATCH_START="$k"
    return 0
  fi
  [ "$word" = "$command" ] || return 1
  for ((k++; k < n; k++)); do
    _clean_command_word "${_HOOK_WATCH_WORDS[k]}" word
    case "$word" in
      -C | -c | --git-dir | --work-tree | --namespace | --exec-path) k=$((k + 1)) ;;
      -*) ;;
      *) break ;;
    esac
  done
  [ "$k" -lt "$n" ] && [ "$word" = "$sub" ] || return 1
  _HOOK_WATCH_START="$k"
}

# _hook_watch_launch <option>[|<option>...] <command> [<subcommand>]
#
# Succeed when an executable fragment of the hook's command runs <command>
# (<subcommand>) with one of the `|`-separated options and without -h/--help (which only prints
# usage). Sets _HOOK_WATCH_DETACHED=1 when such a run is detached: behind
# nohup or setsid, followed by a `disown`, or backgrounded with `&`. A text
# prefilter keeps every other command free of the scan, and only fragments
# naming the command are tokenized.
_hook_watch_launch() {
  local option="$1" command="$2" sub="${3:-}" needle fragment found=0 detached=0
  local i n word option_seen help
  _HOOK_WATCH_DETACHED=0
  needle="${sub:-$command}"
  case "${AGENTGUARD_CMD_TRIMMED:-}" in *"$needle"*) ;; *) return 1 ;; esac
  _hook_load_command_classifier || return 1
  if [ "${_HOOK_EXECUTABLE_FRAGMENTS_CACHE_TEXT+x}" != x ] ||
    [ "$_HOOK_EXECUTABLE_FRAGMENTS_CACHE_TEXT" != "$AGENTGUARD_CMD_TRIMMED" ]; then
    _hook_cache_executable_fragments "$AGENTGUARD_CMD_TRIMMED"
  fi
  while IFS= read -r fragment; do
    case "$fragment" in
      *"$needle"*) ;;
      *disown*)
        # A `disown` after the launch detaches it; one before it does not.
        if [ "$found" = 1 ]; then
          _fragment_command_word "$fragment" word
          [ "${word##*/}" != disown ] || detached=1
        fi
        continue
        ;;
      *) continue ;;
    esac
    _HOOK_WATCH_WORDS=()
    _fragment_token_words "$fragment" _HOOK_WATCH_WORDS
    _hook_watch_command_start "$fragment" "$command" "$sub" || continue
    n="${#_HOOK_WATCH_WORDS[@]}"
    option_seen=0 help=0
    for ((i = _HOOK_WATCH_START + 1; i < n; i++)); do
      case "${_HOOK_WATCH_WORDS[i]}" in *[\;\|\&\<\>]*) break ;; esac
      _clean_command_word "${_HOOK_WATCH_WORDS[i]}" word
      case "$word" in
        --) break ;;
        -h | --help) help=1 ;;
        *) case "|$option|" in *"|$word|"*) option_seen=1 ;; esac ;;
      esac
    done
    [ "$option_seen" = 1 ] && [ "$help" = 0 ] || continue
    found=1
    for ((i = 0; i < _HOOK_WATCH_START; i++)); do
      _clean_command_word "${_HOOK_WATCH_WORDS[i]}" word
      case "${word##*/}" in
        nohup | setsid) detached=1 ;;
      esac
    done
  done <<<"$_HOOK_EXECUTABLE_FRAGMENTS_CACHE_VALUE"
  [ "$found" = 1 ] || return 1
  # stderr: the setlocale warning from the scan's local C locale.
  if [ "$detached" = 1 ] || _hook_watch_text_detaches "$needle" "${sub:+$command}" 2>/dev/null; then
    _HOOK_WATCH_DETACHED=1
  fi
  return 0
}
