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
# tool dir with `/` replaced by `_`):
#   tool            three lines: tool dir, watcher argv basename, hint
#   keys/<key>      "<epoch> <scope>" then the label, one file per key
#   blocked/<key>   written when a Stop blocked for that key

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
# dir with `/` replaced by `_`. Fails for an absolute, empty, or unsafe dir.
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
  printf -v "$2" '%s' "${_ti_dir//\//_}"
}

# Store the current epoch in the variable named by $1. Bash 4.2+ formats it
# without a fork; Bash 3.2 asks date(1). Only record and re-arm call this.
_hook_watch_now() {
  local _watch_now=''
  if [ "${BASH_VERSINFO[0]:-0}" -gt 4 ] ||
    { [ "${BASH_VERSINFO[0]:-0}" -eq 4 ] && [ "${BASH_VERSINFO[1]:-0}" -ge 2 ]; }; then
    printf -v _watch_now '%(%s)T' -1
  else
    _watch_now=$(date +%s 2>/dev/null) || _watch_now=''
  fi
  case "$_watch_now" in
    '' | *[!0-9]*) return 1 ;;
  esac
  printf -v "$1" '%s' "$_watch_now"
}

# Replace file $1 with content $2 atomically, so a concurrent Stop reads the
# old record or the new one, never a torn one. The temporary name carries `~`
# like the producer's, and a failure leaves the previous record in place.
_hook_watch_write() {
  local file="$1" tmp="$1~$$"
  [ ! -d "$file" ] || return 1
  if printf '%s\n' "$2" 2>/dev/null >"$tmp" && mv -f -- "$tmp" "$file" 2>/dev/null; then
    return 0
  fi
  rm -f -- "$tmp" 2>/dev/null
  return 1
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
# command line, matched so a path containing spaces still works.
_hook_watch_pid_runs() {
  local pid="$1" name="$2" argv0='' argv1='' command
  case "$pid" in
    '' | 0* | *[!0-9]*) return 1 ;;
  esac
  if [ -r /proc/self/cmdline ]; then
    [ -r "/proc/$pid/cmdline" ] || return 1
    {
      IFS= read -r -d '' argv0 || true
      IFS= read -r -d '' argv1 || true
    } 2>/dev/null <"/proc/$pid/cmdline" || return 1
    [ "${argv0##*/}" = "$name" ] || [ "${argv1##*/}" = "$name" ]
    return
  fi
  kill -0 "$pid" 2>/dev/null || return 1
  command=$(ps -o command= -p "$pid" 2>/dev/null) || return 1
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
        _hook_watch_pid_runs "$pid" "$argv" && return 0
      fi
    done
  done
  return 1
}

# Read the newest done/<key> record across the accepted producer dirs into
# _HOOK_WATCH_DONE_EPOCH (0 for `-`, which counts as before any event) and
# _HOOK_WATCH_DONE_WORD. The content is "<commit> <word> <epoch>"; fails when
# no readable record exists.
_hook_watch_done() {
  local key="$1" dir file word epoch found=1
  _HOOK_WATCH_DONE_EPOCH=0
  _HOOK_WATCH_DONE_WORD=''
  for dir in ${_HOOK_WATCH_DIRS[@]+"${_HOOK_WATCH_DIRS[@]}"}; do
    file="$dir/done/$key"
    _hook_watch_file_ok "$file" || continue
    word='' epoch=''
    read -r _ word epoch 2>/dev/null <"$file" || [ -n "$word" ] || continue
    case "$epoch" in
      '' | *[!0-9]*) epoch=0 ;;
    esac
    # Leading zeros would read as octal below; a producer never writes them.
    epoch="${epoch#"${epoch%%[!0]*}"}"
    epoch="${epoch:-0}"
    [ "${#epoch}" -le 15 ] || continue
    if [ "$found" = 1 ] || [ "$epoch" -gt "$_HOOK_WATCH_DONE_EPOCH" ]; then
      _HOOK_WATCH_DONE_EPOCH="$epoch"
      _HOOK_WATCH_DONE_WORD="$word"
      found=0
    fi
  done
  return "$found"
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
  _hook_watch_write "$1/keys/$2" "$3 $4"$'\n'"$5"
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
  _hook_watch_now now || return 1
  base="$base/$id"
  [ -d "$base" ] || _hook_mkstate "$base" || return 1
  # One line each: a newline would shift every later field.
  label="${label//$'\n'/ }"
  hint="${hint//$'\n'/ }"
  # The tool file rarely changes; rewriting it only when it does saves an mv.
  if ! _hook_watch_read_tool "$base/tool" || [ "$_HOOK_WATCH_TOOL_DIR" != "$tool_dir" ] ||
    [ "$_HOOK_WATCH_TOOL_ARGV" != "$argv" ] || [ "$_HOOK_WATCH_TOOL_HINT" != "$hint" ]; then
    _hook_watch_write "$base/tool" "$tool_dir"$'\n'"$argv"$'\n'"$hint" || return 1
  fi
  _hook_watch_write_key "$base" "$key" "$now" "$scope" "$label"
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
  _hook_watch_now now || return 1
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
# closed (a reopened pull request, say). Prints its label when it re-armed;
# a key this session never recorded is left alone.
_hook_watch_rearm_key() {
  local tool_dir="$1" key="$2" id base now
  _hook_watch_tool_id "$tool_dir" id || return 1
  _hook_watch_name_ok "$key" || return 1
  _hook_watch_session_dir base || return 1
  base="$base/$id"
  _hook_watch_read_key "$base/keys/$key" || return 0
  _hook_watch_now now || return 1
  _hook_watch_write_key "$base" "$key" "$now" "$_HOOK_WATCH_KEY_SCOPE" \
    "$_HOOK_WATCH_KEY_LABEL" &&
    printf '%s\n' "$_HOOK_WATCH_KEY_LABEL"
  return 0
}

# _hook_watch_list <tool-dir>
#
# Print one "<key> <scope> <terminal|open>" line per key this session
# recorded for the tool, uninterpreted. Recognizers use it to map their own
# vocabulary (a repository, a number) onto recorded keys.
_hook_watch_list() {
  local tool_dir="$1" id base file key state
  _hook_watch_tool_id "$tool_dir" id || return 1
  _hook_watch_session_dir base || return 1
  base="$base/$id"
  [ -d "$base/keys" ] || return 0
  _hook_watch_roots "$tool_dir" || _HOOK_WATCH_DIRS=()
  for file in "$base/keys"/*; do
    key="${file##*/}"
    _hook_watch_name_ok "$key" || continue
    _hook_watch_read_key "$file" || continue
    state=open
    _hook_watch_terminal "$key" && state=terminal
    printf '%s %s %s\n' "$key" "$_HOOK_WATCH_KEY_SCOPE" "$state"
  done
  return 0
}

# Whether recorded key $1 (scope $2, submitted at epoch $3) is satisfied: a
# live watcher or matching pending file, or a done record whose check started
# after the submit (a check that started in the same second may not have seen
# it, so equal epochs do not count). Per the producer contract, watchers/ is
# listed before done/ and once more when neither shows anything, because one
# listing can miss a watcher file while another replaces it.
_hook_watch_satisfied() {
  local key="$1" scope="$2" epoch="$3" argv="$4"
  _hook_watch_watched "$key" "$scope" "$argv" && return 0
  if _hook_watch_done "$key" && [ "$_HOOK_WATCH_DONE_EPOCH" -gt "$epoch" ]; then
    return 0
  fi
  _hook_watch_watched "$key" "$scope" "$argv"
}

# _hook_watch_collect
#
# Fill _HOOK_WATCH_UNMET with "<tool-id> <key>" for every key this session
# recorded that no watcher covers and no newer done record satisfies. A tool
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
# was recorded yet, or when the key was recorded or re-armed (keys/<key>) or
# a watcher run for it ended (the producer's exited/<key>) since the last
# block. Every re-arm needs new work or a new watcher run in between, so
# blocks stay bounded and a Stop can always end the turn. The claim holds
# only once the marker is written: an unwritable state dir degrades to a
# reminder, never to a block on every Stop.
_hook_watch_claim_block() {
  local tool_dir="$1" key="$2" id base marker dir armed=0
  _hook_watch_tool_id "$tool_dir" id || return 1
  _hook_watch_name_ok "$key" || return 1
  _hook_watch_session_dir base || return 1
  base="$base/$id"
  marker="$base/blocked/$key"
  if [ ! -e "$marker" ] || [ "$base/keys/$key" -nt "$marker" ]; then
    armed=1
  elif _hook_watch_roots "$tool_dir"; then
    for dir in ${_HOOK_WATCH_DIRS[@]+"${_HOOK_WATCH_DIRS[@]}"}; do
      if _hook_watch_file_ok "$dir/exited/$key" && [ "$dir/exited/$key" -nt "$marker" ]; then
        armed=1
      fi
    done
  fi
  [ "$armed" = 1 ] || return 1
  [ -d "$base/blocked" ] || _hook_mkstate "$base/blocked" || return 1
  # Write content, not just truncate: O_TRUNC on an empty file need not bump
  # its mtime, which is what the arming comparison reads.
  printf '%s\n' "$$" 2>/dev/null >"$marker"
}

# _hook_watch_stop [<tool-dir>=<VARIABLE>]...
#
# The Stop hook's watch pass. Call it only for a foreground Stop. Reminds on
# stderr once per prompt per key and submit; with AGENTGUARD_WATCH_BLOCK=1 on
# Claude, also blocks once per submit or watcher exit (see
# _hook_watch_claim_block). Each argument names the hook-environment variable
# that turns a tool's producer state off when set to the literal `0`; such a
# tool gets one note saying so instead of reminders it could never satisfy.
_hook_watch_stop() {
  local entry id key tool_base pair var block=0 agent message remind='' blocks=''
  local current='' remind_labels='' block_labels='' off='' skip=0
  _hook_watch_collect
  [ "${#_HOOK_WATCH_UNMET[@]}" -gt 0 ] || return 0
  if _hook_flag_enabled "${AGENTGUARD_WATCH_BLOCK:-}"; then
    _hook_agent_name agent
    [ "$agent" != claude ] || block=1
  fi
  # Entries arrive grouped by tool; flush one message per tool.
  for entry in ${_HOOK_WATCH_UNMET[@]+"${_HOOK_WATCH_UNMET[@]}"} '- -'; do
    id="${entry%% *}"
    key="${entry#* }"
    if [ "$id" != "$current" ] && [ -n "$current" ]; then
      if [ -n "$off" ]; then
        if _hook_once_per_prompt "watch-off-$current"; then
          remind="$remind${remind:+ }$off=0 in the hook environment turns $_HOOK_WATCH_TOOL_ARGV state files off, so AgentGuard cannot tell whether$remind_labels is watched. Unset it to restore this check."
        fi
      else
        [ -z "$remind_labels" ] ||
          remind="$remind${remind:+ }Not watched since the last push or submit:$remind_labels. $_HOOK_WATCH_TOOL_HINT"
        [ -z "$block_labels" ] ||
          blocks="$blocks${blocks:+ }Not watched since the last push or submit:$block_labels. $_HOOK_WATCH_TOOL_HINT"
      fi
      remind_labels='' block_labels=''
    fi
    [ "$id" != - ] || break
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
    # Claim the prompt marker first so a key this Stop blocks for is not
    # reminded again by the Stop that follows in the same prompt.
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
    _hook_block "$blocks (AGENTGUARD_WATCH_BLOCK=1 blocks one Stop per push, submit, or watcher exit.)"
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
# `/`, or `-` boundary and ends at whitespace: `pr-watch.log` is a file), and
# a lone `&` anywhere in the rest of its and-or list (up to `;` or the line's
# end, ignoring `&&`, `>&`, `&>`, `<&`, and `|&`) backgrounds the whole list.
# Lines without both the name and an `&` are skipped unmasked. An `&` inside
# `bash -c '...'`, `{ ...; } &`, and ANSI-C quoting are not modeled.
_hook_watch_text_detaches() {
  local needle="$1" line rest before seg LC_ALL=C
  while IFS= read -r line; do
    case "$line" in *"$needle"*) ;; *) continue ;; esac
    case "$line" in *'&'*) ;; *) continue ;; esac
    _hook_watch_unquoted "$line" rest
    while :; do
      case "$rest" in *"$needle"*) ;; *) break ;; esac
      before="${rest%%"$needle"*}"
      rest="${rest:${#before}+${#needle}}"
      case "$rest" in '' | [[:space:]]*) ;; *) continue ;; esac
      case "$before" in '' | *[[:space:]/\(-]) ;; *) continue ;; esac
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
# also skips the wrappers it keeps as the command word (setsid, stdbuf).
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

# _hook_watch_launch <option> <command> [<subcommand>]
#
# Succeed when an executable fragment of the hook's command runs <command>
# (<subcommand>) with <option> and without -h/--help (which only prints
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
        "$option") option_seen=1 ;;
        -h | --help) help=1 ;;
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
  if [ "$detached" = 1 ] || _hook_watch_text_detaches "$needle"; then
    _HOOK_WATCH_DETACHED=1
  fi
  return 0
}
