#!/usr/bin/env bash
# hook-command-classifier.sh — shallow Bash command classification helpers.
#
# This is intentionally not a full shell parser. Agent hooks need fast,
# conservative classification for guard policies such as nested shell payloads
# and protected bare-Git untracked scans.

_strip_outer_quotes() {
  local value="$1"
  value="${value%\"}"
  value="${value#\"}"
  value="${value%\'}"
  value="${value#\'}"
  printf '%s' "$value"
}

_shell_word_token() {
  local value
  value="$(_strip_outer_quotes "$1")"
  value="${value//\"/}"
  value="${value//\'/}"
  value="${value//\\/}"
  printf '%s' "$value"
}

_trim_hook_fragment() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

# Heredoc delimiters decide whether the body is executable input or inert prose.
# Keep that parsing centralized so the line splitter, generic command guards,
# and protected bare-Git scan blocker agree on multiple heredocs, quoted delimiters, and
# `<<-` tab stripping.
_heredoc_specs() {
  local line="$1" quote="" ch next next2 delim active strip_tabs marker_quote="" escaped=0
  local i j

  for ((i = 0; i < ${#line}; i++)); do
    ch="${line:i:1}"
    next="${line:i+1:1}"
    next2="${line:i+2:1}"

    if [ "$escaped" -eq 1 ]; then
      escaped=0
      continue
    fi
    if [ "$ch" = "\\" ] && [ "$quote" != "'" ]; then
      escaped=1
      continue
    fi
    if [ -n "$quote" ]; then
      if [ "$quote" = "ansi" ]; then
        [ "$ch" = "'" ] && quote=""
      else
        [ "$ch" = "$quote" ] && quote=""
      fi
      continue
    fi
    case "$ch" in
      "$")
        if [ "$next" = "'" ]; then
          quote="ansi"
          ((i++))
          continue
        fi
        ;;
      "'" | '"')
        quote="$ch"
        continue
        ;;
    esac

    [ "$ch" = "<" ] || continue
    [ "$next" = "<" ] || continue
    [ "$next2" = "<" ] && continue

    j=$((i + 2))
    strip_tabs=0
    if [ "${line:j:1}" = "-" ]; then
      strip_tabs=1
      ((j++))
    fi
    while [ "$j" -lt "${#line}" ] && [[ "${line:j:1}" == [[:space:]] ]]; do
      ((j++))
    done

    delim=""
    active=1
    marker_quote=""
    while [ "$j" -lt "${#line}" ]; do
      ch="${line:j:1}"
      if [ -n "$marker_quote" ]; then
        if [ "$marker_quote" = "ansi" ]; then
          if [ "$ch" = "'" ]; then
            marker_quote=""
          elif [ "$ch" = "\\" ]; then
            ((j++))
            [ "$j" -lt "${#line}" ] && delim+="${line:j:1}"
          else
            delim+="$ch"
          fi
        elif [ "$ch" = "$marker_quote" ]; then
          marker_quote=""
        elif [ "$ch" = "\\" ] && [ "$marker_quote" = '"' ]; then
          ((j++))
          [ "$j" -lt "${#line}" ] && delim+="${line:j:1}"
        else
          delim+="$ch"
        fi
        ((j++))
        continue
      fi

      case "$ch" in
        [[:space:]] | ';' | '|' | '&' | '<' | '>')
          break
          ;;
        "'" | '"')
          active=0
          marker_quote="$ch"
          ;;
        "$")
          # Bash treats `$'EOF'` as a quoted heredoc delimiter after quote
          # removal. If we keep the literal `$`, the scanner waits for `$EOF`
          # forever and incorrectly hides commands after the real `EOF`.
          if [ "${line:j+1:1}" = "'" ]; then
            active=0
            marker_quote="ansi"
            ((j++))
          else
            delim+="$ch"
          fi
          ;;
        "\\")
          active=0
          ((j++))
          [ "$j" -lt "${#line}" ] && delim+="${line:j:1}"
          ;;
        *)
          delim+="$ch"
          ;;
      esac
      ((j++))
    done

    [ -n "$delim" ] && printf '%s\t%s\t%s\n' "$delim" "$strip_tabs" "$active"
    i=$((j - 1))
  done
}

_logical_command_incomplete() {
  local text="$1" ch next next2 quote="" paren_outer_quote="" escaped=0 in_backtick=0 in_paren=0 in_arith=0 paren_depth=0 arith_depth=0
  local i

  for ((i = 0; i < ${#text}; i++)); do
    ch="${text:i:1}"
    next="${text:i+1:1}"
    next2="${text:i+2:1}"

    if [ "$escaped" -eq 1 ]; then
      escaped=0
      continue
    fi
    if [ "$ch" = "\\" ] && [ "$quote" != "'" ]; then
      escaped=1
      continue
    fi

    if [ "$in_backtick" -eq 1 ]; then
      [ "$ch" = "\`" ] && in_backtick=0
      continue
    fi

    if [ "$in_arith" -eq 1 ]; then
      if [ -n "$quote" ]; then
        if [ "$quote" = "ansi" ]; then
          [ "$ch" = "'" ] && quote=""
        else
          [ "$ch" = "$quote" ] && quote=""
        fi
        continue
      fi
      case "$ch" in
        "$")
          if [ "$next" = "'" ]; then
            quote="ansi"
            ((i++))
          fi
          ;;
        "'" | '"')
          quote="$ch"
          ;;
        "\`")
          in_backtick=1
          ;;
        "(")
          arith_depth=$((arith_depth + 1))
          ;;
        ")")
          if [ "$next" = ")" ] && [ "$arith_depth" -eq 0 ]; then
            in_arith=0
            quote="$paren_outer_quote"
            paren_outer_quote=""
            ((i++))
          elif [ "$arith_depth" -gt 0 ]; then
            arith_depth=$((arith_depth - 1))
          fi
          ;;
      esac
      continue
    fi

    if [ "$in_paren" -eq 1 ]; then
      if [ -n "$quote" ]; then
        if [ "$quote" = "ansi" ]; then
          [ "$ch" = "'" ] && quote=""
        else
          [ "$ch" = "$quote" ] && quote=""
        fi
        continue
      fi
      case "$ch" in
        "'" | '"')
          quote="$ch"
          ;;
        "\`")
          in_backtick=1
          ;;
        "$")
          if [ "$next" = "'" ]; then
            quote="ansi"
            ((i++))
          elif [ "$next" = "(" ]; then
            paren_depth=$((paren_depth + 1))
            ((i++))
          fi
          ;;
        "<" | ">")
          if [ "$next" = "(" ]; then
            paren_depth=$((paren_depth + 1))
            ((i++))
          fi
          ;;
        "(")
          paren_depth=$((paren_depth + 1))
          ;;
        ")")
          if [ "$paren_depth" -eq 0 ]; then
            in_paren=0
            quote="$paren_outer_quote"
            paren_outer_quote=""
          else
            paren_depth=$((paren_depth - 1))
          fi
          ;;
      esac
      continue
    fi

    if [ "$quote" = "ansi" ]; then
      [ "$ch" = "'" ] && quote=""
      continue
    fi
    if [ "$quote" = "'" ]; then
      [ "$ch" = "'" ] && quote=""
      continue
    fi
    if [ "$quote" = '"' ]; then
      case "$ch" in
        '"')
          quote=""
          ;;
        "\`")
          in_backtick=1
          ;;
        "$")
          if [ "$next" = "(" ] && [ "$next2" = "(" ]; then
            in_arith=1
            paren_outer_quote="$quote"
            quote=""
            arith_depth=0
            i=$((i + 2))
          elif [ "$next" = "(" ]; then
            in_paren=1
            paren_outer_quote="$quote"
            quote=""
            paren_depth=0
            ((i++))
          fi
          ;;
        "<" | ">")
          if [ "$next" = "(" ]; then
            in_paren=1
            paren_outer_quote="$quote"
            quote=""
            paren_depth=0
            ((i++))
          fi
          ;;
      esac
      continue
    fi

    case "$ch" in
      "'" | '"')
        quote="$ch"
        ;;
      "\`")
        in_backtick=1
        ;;
      "$")
        if [ "$next" = "'" ]; then
          quote="ansi"
          ((i++))
        elif [ "$next" = "(" ] && [ "$next2" = "(" ]; then
          in_arith=1
          paren_outer_quote="$quote"
          quote=""
          arith_depth=0
          i=$((i + 2))
        elif [ "$next" = "(" ]; then
          in_paren=1
          paren_outer_quote="$quote"
          quote=""
          paren_depth=0
          ((i++))
        fi
        ;;
      "<" | ">")
        if [ "$next" = "(" ]; then
          in_paren=1
          paren_outer_quote="$quote"
          quote=""
          paren_depth=0
          ((i++))
        fi
        ;;
    esac
  done

  [ -n "$quote" ] || [ "$in_backtick" -eq 1 ] || [ "$in_paren" -eq 1 ] || [ "$in_arith" -eq 1 ]
}

# Hook latency matters. This is a shallow scanner for command lines the agent
# sends us: join backslash continuations, skip heredoc bodies, and leave full
# Bash parsing to Bash. The protected bare-Git guard only needs executable
# fragments.
# Records are NUL-delimited because a single logical command can legally contain
# embedded newlines inside quotes or command substitutions; newline-delimited
# streams would turn inert prose into fake executable fragments.
_hook_command_lines() {
  local text="${1:-$AGENTGUARD_CMD_TRIMMED}"
  local line pending="" marker delim strip_tabs _active
  local -a heredoc_delims=() heredoc_strips=()

  while IFS= read -r line || [ -n "$line" ]; do
    if [ "${#heredoc_delims[@]}" -gt 0 ]; then
      marker="$line"
      if [ "${heredoc_strips[0]}" -eq 1 ]; then
        while [[ "$marker" == $'\t'* ]]; do
          marker="${marker#$'\t'}"
        done
      fi
      if [ "$marker" = "${heredoc_delims[0]}" ]; then
        heredoc_delims=("${heredoc_delims[@]:1}")
        heredoc_strips=("${heredoc_strips[@]:1}")
      fi
      continue
    fi

    pending="$(_append_pending_command_line "$pending" "$line")"

    if ! _pending_command_complete "$pending"; then
      continue
    fi

    printf '%s\0' "$pending"
    while IFS=$'\t' read -r delim strip_tabs _active; do
      [ -n "$delim" ] || continue
      heredoc_delims+=("$delim")
      heredoc_strips+=("$strip_tabs")
    done < <(_heredoc_specs "$pending")
    pending=""
  done <<<"$text"

  [ -n "$pending" ] && printf '%s\0' "$pending"
}

_pending_command_complete() {
  local pending="$1"
  [[ "$pending" != *\\ ]] && ! _logical_command_incomplete "$pending"
}

_append_pending_command_line() {
  local pending="$1" line="$2"
  if [ -n "$pending" ]; then
    if [[ "$pending" == *\\ ]]; then
      pending="${pending%\\} $line"
    else
      pending+=$'\n'"$line"
    fi
  else
    pending="$line"
  fi
  printf '%s' "$pending"
}

_append_heredoc_body_line() {
  local body="$1" line="$2"
  if [ -n "$body" ]; then
    body+=$'\n'"$line"
  else
    body="$line"
  fi
  printf '%s' "$body"
}

_flush_active_heredoc_payloads() {
  local body="$1" active="${2:-0}"
  # Bash accepts a heredoc that reaches EOF before its delimiter, emits a
  # warning, and still expands the body. Hooks see the pre-execution command
  # text, so EOF must be treated as a delimiter for classification purposes.
  [ "$active" -eq 1 ] || return 0
  _executable_expansion_payloads "$body"
}

# `$'...'` is data, not an executable expansion context. It still needs a
# distinct quote mode because `\'` is an escaped quote there, unlike normal
# single quotes; otherwise inert test/doc strings can look like live `$()`.
_split_command_fragments() {
  local line="$1" buf="" quote="" ch next fragment escaped=0
  local i

  for ((i = 0; i < ${#line}; i++)); do
    ch="${line:i:1}"
    next="${line:i+1:1}"
    if [ "$escaped" -eq 1 ]; then
      buf+="$ch"
      escaped=0
      continue
    fi
    if [ "$ch" = "\\" ] && [ "$quote" != "'" ]; then
      buf+="$ch"
      escaped=1
      continue
    fi
    if [ -n "$quote" ]; then
      if [ "$quote" = "ansi" ]; then
        [ "$ch" = "'" ] && quote=""
      else
        [ "$ch" = "$quote" ] && quote=""
      fi
      buf+="$ch"
      continue
    fi

    case "$ch" in
      "$")
        if [ "$next" = "'" ]; then
          quote="ansi"
          buf+="$ch$next"
          ((i++))
        else
          buf+="$ch"
        fi
        ;;
      "'" | '"')
        quote="$ch"
        buf+="$ch"
        ;;
      ';' | '&' | '|')
        fragment="$(_trim_hook_fragment "$buf")"
        [ -n "$fragment" ] && printf '%s\n' "$fragment"
        buf=""
        if { [ "$ch" = "&" ] || [ "$ch" = "|" ]; } && [ "$next" = "$ch" ]; then
          ((i++))
        fi
        ;;
      *)
        buf+="$ch"
        ;;
    esac
  done

  fragment="$(_trim_hook_fragment "$buf")"
  [ -n "$fragment" ] && printf '%s\n' "$fragment"
}

_hook_command_fragments() {
  local text="${1:-$AGENTGUARD_CMD_TRIMMED}" command
  while IFS= read -r -d '' command; do
    _split_command_fragments "${command//$'\n'/ }"
  done < <(_hook_command_lines "$text")
}

_unquoted_char_index() {
  local text="$1" needle="$2" quote="" ch next escaped=0
  local i

  for ((i = 0; i < ${#text}; i++)); do
    ch="${text:i:1}"
    next="${text:i+1:1}"

    if [ "$escaped" -eq 1 ]; then
      escaped=0
      continue
    fi
    if [ "$ch" = "\\" ] && [ "$quote" != "'" ]; then
      escaped=1
      continue
    fi
    if [ -n "$quote" ]; then
      if { [ "$quote" = "ansi" ] && [ "$ch" = "'" ]; } ||
        { [ "$quote" != "ansi" ] && [ "$ch" = "$quote" ]; }; then
        quote=""
      fi
      continue
    fi

    case "$ch" in
      "$")
        if [ "$next" = "'" ]; then
          quote="ansi"
          ((i++))
          continue
        fi
        ;;
      "'" | '"')
        quote="$ch"
        continue
        ;;
    esac

    if [ "$ch" = "$needle" ]; then
      printf '%s' "$i"
      return 0
    fi
  done

  return 1
}

_function_definition_name() {
  local fragment="$1" word raw0 raw1 raw2 name
  local -a words=()

  while IFS= read -r word; do
    words+=("$word")
  done < <(_fragment_tokens "$fragment")
  [ "${#words[@]}" -gt 0 ] || return 1

  raw0="${words[0]}"
  raw1="${words[1]:-}"
  raw2="${words[2]:-}"

  if [[ "$raw0" =~ ^[A-Za-z_][A-Za-z0-9_]*\(\)\{$ ]]; then
    name="${raw0%%()*}"
  elif [[ "$raw0" =~ ^[A-Za-z_][A-Za-z0-9_]*$ && "$raw1" = "()" && "$raw2" = "{" ]]; then
    name="$raw0"
  elif [ "$raw0" = "function" ] &&
    [[ "$raw1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ && "$raw2" = "{" ]]; then
    name="$raw1"
  elif [ "$raw0" = "function" ] &&
    [[ "$raw1" =~ ^[A-Za-z_][A-Za-z0-9_]*\(\)$ && "$raw2" = "{" ]]; then
    name="${raw1%%()*}"
  elif [ "$raw0" = "function" ] &&
    [[ "$raw1" =~ ^[A-Za-z_][A-Za-z0-9_]*\(\)\{$ ]]; then
    name="${raw1%%()*}"
  else
    return 1
  fi

  printf '%s\n' "$name"
}

_function_body_payload() {
  local fragment="$1" index payload

  _function_definition_name "$fragment" >/dev/null || return 1
  index="$(_unquoted_char_index "$fragment" "{")" || return 1
  payload="$(_trim_hook_fragment "${fragment:$((index + 1))}")"
  [ -n "$payload" ] || return 1
  printf '%s\n' "$payload"
}

_case_arm_payload() {
  local fragment="$1" word first index payload
  word="$(_fragment_command_word "$fragment")" || return 1
  if [ "$word" != "case" ]; then
    first="$(_first_shell_word "$fragment")" || return 1
    # `_split_command_fragments` separates `;;`, so later case arms arrive as
    # `pattern) command`. Treat only a leading pattern terminator as a case body
    # to avoid interpreting arbitrary arguments containing `)` as shell code.
    case "$first" in
      *")") ;;
      *) return 1 ;;
    esac
  fi

  index="$(_unquoted_char_index "$fragment" ")")" || return 1
  payload="$(_trim_hook_fragment "${fragment:$((index + 1))}")"
  [ -n "$payload" ] || return 1
  printf '%s\n' "$payload"
}

_structural_shell_payloads() {
  local fragment="$1"

  # These bodies are executable shell regions, but they are not command words
  # themselves. Extract them in one shared place so rm/find/grep/git policies
  # do not each learn their own partial model of shell structure.
  _case_arm_payload "$fragment" || true
  _function_body_payload "$fragment" || true
}

# Command and process substitutions are executable code even when the top-level
# command is harmless-looking (`echo $(rm -rf /)`, `cat <(git status -uall)`).
# Guard classifiers need to inspect those payloads without treating ordinary
# quoted prose as code, so this bounded scanner extracts only executable
# expansion bodies for recursive classification.
_executable_expansion_payloads() {
  local fragment="$1" ch next next2 quote="" paren_outer_quote="" payload="" arith_payload="" escaped=0 depth=0 arith_depth=0 in_paren=0 in_backtick=0 in_arith=0
  local i

  for ((i = 0; i < ${#fragment}; i++)); do
    ch="${fragment:i:1}"
    next="${fragment:i+1:1}"
    next2="${fragment:i+2:1}"

    if [ "$escaped" -eq 1 ]; then
      if [ "$in_arith" -eq 1 ]; then
        arith_payload+="$ch"
      elif [ "$in_paren" -eq 1 ] || [ "$in_backtick" -eq 1 ]; then
        payload+="$ch"
      fi
      escaped=0
      continue
    fi

    if [ "$ch" = "\\" ] && [ "$quote" != "'" ]; then
      if [ "$in_arith" -eq 1 ]; then
        arith_payload+="$ch"
      elif [ "$in_paren" -eq 1 ] || [ "$in_backtick" -eq 1 ]; then
        payload+="$ch"
      fi
      escaped=1
      continue
    fi

    if [ "$in_backtick" -eq 1 ]; then
      if [ "$ch" = "\`" ]; then
        [ -n "$payload" ] && printf '%s\0' "$payload"
        payload=""
        in_backtick=0
      else
        payload+="$ch"
      fi
      continue
    fi

    if [ "$in_arith" -eq 1 ]; then
      if [ -n "$quote" ]; then
        if { [ "$quote" = "ansi" ] && [ "$ch" = "'" ]; } ||
          { [ "$quote" != "ansi" ] && [ "$ch" = "$quote" ]; }; then
          quote=""
        fi
        arith_payload+="$ch"
        continue
      fi
      case "$ch" in
        "$")
          if [ "$next" = "'" ]; then
            quote="ansi"
            arith_payload+="$ch$next"
            ((i++))
          else
            arith_payload+="$ch"
          fi
          ;;
        "'" | '"')
          quote="$ch"
          arith_payload+="$ch"
          ;;
        "(")
          arith_depth=$((arith_depth + 1))
          arith_payload+="$ch"
          ;;
        ")")
          if [ "$next" = ")" ] && [ "$arith_depth" -eq 0 ]; then
            # Arithmetic expansion itself does not execute command words, but
            # command substitutions nested inside it still do. Re-scan only the
            # arithmetic body for executable expansions instead of classifying
            # the body as a command.
            [ -n "$arith_payload" ] && _executable_expansion_payloads "$arith_payload"
            arith_payload=""
            in_arith=0
            quote="$paren_outer_quote"
            paren_outer_quote=""
            ((i++))
          else
            [ "$arith_depth" -gt 0 ] && arith_depth=$((arith_depth - 1))
            arith_payload+="$ch"
          fi
          ;;
        *)
          arith_payload+="$ch"
          ;;
      esac
      continue
    fi

    if [ "$in_paren" -eq 1 ]; then
      if [ -n "$quote" ]; then
        if { [ "$quote" = "ansi" ] && [ "$ch" = "'" ]; } ||
          { [ "$quote" != "ansi" ] && [ "$ch" = "$quote" ]; }; then
          quote=""
        fi
        payload+="$ch"
        continue
      fi
      case "$ch" in
        "$")
          if [ "$next" = "'" ]; then
            quote="ansi"
            payload+="$ch$next"
            ((i++))
          else
            payload+="$ch"
          fi
          ;;
        "'" | '"')
          quote="$ch"
          payload+="$ch"
          ;;
        "(")
          depth=$((depth + 1))
          payload+="$ch"
          ;;
        ")")
          if [ "$depth" -eq 0 ]; then
            [ -n "$payload" ] && printf '%s\0' "$payload"
            payload=""
            in_paren=0
            quote="$paren_outer_quote"
            paren_outer_quote=""
          else
            depth=$((depth - 1))
            payload+="$ch"
          fi
          ;;
        *)
          payload+="$ch"
          ;;
      esac
      continue
    fi

    if [ "$quote" = "ansi" ]; then
      [ "$ch" = "'" ] && quote=""
      continue
    fi
    if [ "$quote" = "'" ]; then
      [ "$ch" = "'" ] && quote=""
      continue
    fi

    # Bash still runs command/process substitutions inside double quotes, and
    # single quotes are just literal characters there. Keep scanning executable
    # expansions while double-quoted so guards do not miss payloads.
    if [ "$quote" = '"' ]; then
      case "$ch" in
        '"')
          quote=""
          ;;
        "\`")
          in_backtick=1
          payload=""
          ;;
        "$")
          if [ "$next" = "(" ] && [ "$next2" = "(" ]; then
            in_arith=1
            paren_outer_quote="$quote"
            quote=""
            arith_payload=""
            arith_depth=0
            i=$((i + 2))
          elif [ "$next" = "(" ]; then
            in_paren=1
            paren_outer_quote="$quote"
            quote=""
            payload=""
            depth=0
            ((i++))
          fi
          ;;
        "<" | ">")
          if [ "$next" = "(" ]; then
            in_paren=1
            paren_outer_quote="$quote"
            quote=""
            payload=""
            depth=0
            ((i++))
          fi
          ;;
      esac
      continue
    fi

    case "$ch" in
      "'")
        quote="$ch"
        ;;
      '"')
        if [ "$quote" = '"' ]; then
          quote=""
        else
          quote="$ch"
        fi
        ;;
      "\`")
        in_backtick=1
        payload=""
        ;;
      "$")
        if [ "$next" = "'" ]; then
          quote="ansi"
          ((i++))
        elif [ "$next" = "(" ] && [ "$next2" = "(" ]; then
          in_arith=1
          paren_outer_quote="$quote"
          quote=""
          arith_payload=""
          arith_depth=0
          i=$((i + 2))
        elif [ "$next" = "(" ]; then
          in_paren=1
          paren_outer_quote="$quote"
          quote=""
          payload=""
          depth=0
          ((i++))
        fi
        ;;
      "<" | ">")
        if [ "$next" = "(" ]; then
          in_paren=1
          paren_outer_quote="$quote"
          quote=""
          payload=""
          depth=0
          ((i++))
        fi
        ;;
    esac
  done
}

_active_heredoc_payloads() {
  local text="$1" line pending="" marker body="" delim strip_tabs active
  local -a heredoc_delims=() heredoc_strips=() heredoc_actives=()

  while IFS= read -r line || [ -n "$line" ]; do
    if [ "${#heredoc_delims[@]}" -gt 0 ]; then
      marker="$line"
      if [ "${heredoc_strips[0]}" -eq 1 ]; then
        while [[ "$marker" == $'\t'* ]]; do
          marker="${marker#$'\t'}"
        done
      fi
      if [ "$marker" = "${heredoc_delims[0]}" ]; then
        # Heredoc expansion is scoped to the whole body, not one physical line.
        # Accumulating the body keeps multiline command substitutions visible
        # without treating inert body prose as top-level shell code.
        _flush_active_heredoc_payloads "$body" "${heredoc_actives[0]}"
        body=""
        heredoc_delims=("${heredoc_delims[@]:1}")
        heredoc_strips=("${heredoc_strips[@]:1}")
        heredoc_actives=("${heredoc_actives[@]:1}")
        continue
      fi
      if [ "${heredoc_actives[0]}" -eq 1 ]; then
        body="$(_append_heredoc_body_line "$body" "$line")"
      fi
      continue
    fi

    pending="$(_append_pending_command_line "$pending" "$line")"
    if ! _pending_command_complete "$pending"; then
      continue
    fi

    while IFS=$'\t' read -r delim strip_tabs active; do
      [ -n "$delim" ] || continue
      heredoc_delims+=("$delim")
      heredoc_strips+=("$strip_tabs")
      heredoc_actives+=("$active")
    done < <(_heredoc_specs "$pending")
    pending=""
  done <<<"$text"

  [ "${#heredoc_delims[@]}" -gt 0 ] &&
    _flush_active_heredoc_payloads "$body" "${heredoc_actives[0]}"
}

_hook_executable_fragments_uncached() {
  local text="$1" depth="${2:-0}" command fragment payload

  while IFS= read -r -d '' command; do
    # Split a normalized parent fragment for command-word classifiers, but scan
    # executable expansions from the original command so nested heredocs keep
    # their newlines and can be classified accurately.
    while IFS= read -r fragment; do
      printf '%s\n' "$fragment"
      if [ "$depth" -lt 2 ]; then
        while IFS= read -r payload; do
          _hook_executable_fragments "$payload" $((depth + 1))
        done < <(_structural_shell_payloads "$fragment")
        while IFS= read -r payload; do
          _hook_executable_fragments "$payload" $((depth + 1))
        done < <(_nested_shell_payloads "$fragment")
      fi
    done < <(_split_command_fragments "${command//$'\n'/ }")

    # Keep recursion bounded: hooks need conservative classification, not an
    # unbounded shell interpreter. Two levels catches normal agent-generated
    # wrappers while preventing pathological input from burning hook time.
    if [ "$depth" -lt 2 ]; then
      while IFS= read -r -d '' payload; do
        _hook_executable_fragments "$payload" $((depth + 1))
      done < <(_executable_expansion_payloads "$command")
      while IFS= read -r payload; do
        _hook_executable_fragments "$payload" $((depth + 1))
      done < <(_env_split_payloads "$command")
    fi
  done < <(_hook_command_lines "$text")

  # Unquoted heredoc bodies perform expansions before the command receives
  # stdin. Scan only those executable expansion payloads; the surrounding body
  # text remains prose so commit messages and generated files do not false-block.
  if [ "$depth" -lt 2 ]; then
    while IFS= read -r -d '' payload; do
      _hook_executable_fragments "$payload" $((depth + 1))
    done < <(_active_heredoc_payloads "$text")
  fi
}

_hook_executable_fragments() {
  local text="$1" depth="${2:-0}" fragments

  # The pre-bash hook asks many independent guards the same top-level question.
  # Cache only depth-0 scans so recursive payload scans keep their bounded,
  # freshly computed behavior.
  if [ "$depth" -eq 0 ] &&
    [ "${_HOOK_EXECUTABLE_FRAGMENTS_CACHE_TEXT+x}" = "x" ] &&
    [ "$_HOOK_EXECUTABLE_FRAGMENTS_CACHE_TEXT" = "$text" ]; then
    [ -n "$_HOOK_EXECUTABLE_FRAGMENTS_CACHE_VALUE" ] &&
      printf '%s\n' "$_HOOK_EXECUTABLE_FRAGMENTS_CACHE_VALUE"
    return 0
  fi

  fragments="$(_hook_executable_fragments_uncached "$text" "$depth")"
  if [ "$depth" -eq 0 ]; then
    _HOOK_EXECUTABLE_FRAGMENTS_CACHE_TEXT="$text"
    _HOOK_EXECUTABLE_FRAGMENTS_CACHE_VALUE="$fragments"
  fi
  [ -n "$fragments" ] && printf '%s\n' "$fragments"
}

_hook_cache_executable_fragments() {
  local text="$1"
  _HOOK_EXECUTABLE_FRAGMENTS_CACHE_TEXT="$text"
  _HOOK_EXECUTABLE_FRAGMENTS_CACHE_VALUE="$(_hook_executable_fragments_uncached "$text" 0)"
}

# Tokenize one command fragment into shell words, preserving quoted whitespace
# as part of the word. This is still a shallow lexer: it strips quotes and
# backslash escapes, but it does not evaluate expansions or substitutions.
_fragment_tokens() {
  local fragment="$1" ch quote="" word="" escaped=0 started=0
  local i

  for ((i = 0; i < ${#fragment}; i++)); do
    ch="${fragment:i:1}"
    next="${fragment:i+1:1}"
    if [ "$escaped" -eq 1 ]; then
      word+="$ch"
      escaped=0
      started=1
      continue
    fi

    if [ "$ch" = "\\" ] && [ "$quote" != "'" ]; then
      escaped=1
      started=1
      continue
    fi

    if [ -n "$quote" ]; then
      if { [ "$quote" = "ansi" ] && [ "$ch" = "'" ]; } ||
        { [ "$quote" != "ansi" ] && [ "$ch" = "$quote" ]; }; then
        quote=""
      else
        word+="$ch"
      fi
      started=1
      continue
    fi

    case "$ch" in
      "$")
        if [ "$next" = "'" ]; then
          quote="ansi"
          started=1
          ((i++))
        else
          word+="$ch"
          started=1
        fi
        ;;
      "'" | '"')
        quote="$ch"
        started=1
        ;;
      [[:space:]])
        if [ "$started" -eq 1 ]; then
          printf '%s\n' "$word"
          word=""
          started=0
        fi
        ;;
      *)
        word+="$ch"
        started=1
        ;;
    esac
  done

  if [ "$escaped" -eq 1 ]; then
    word+="\\"
  fi
  [ "$started" -eq 1 ] && printf '%s\n' "$word"
}

_protected_bare_git_configured() {
  [ -n "${AGENTGUARD_PROTECTED_BARE_GIT_DIR:-}" ]
}

_protected_bare_git_dir() {
  _protected_bare_git_configured || return 1
  printf '%s\n' "$AGENTGUARD_PROTECTED_BARE_GIT_DIR"
}

_protected_bare_git_work_tree() {
  _protected_bare_git_configured || return 1
  printf '%s\n' "${AGENTGUARD_PROTECTED_BARE_GIT_WORK_TREE:-${HOME:-}}"
}

_protected_bare_git_alias_configured() {
  local wanted="$1" alias_name
  for alias_name in ${AGENTGUARD_PROTECTED_BARE_GIT_ALIASES:-}; do
    [ "$alias_name" = "$wanted" ] && return 0
  done
  return 1
}

_protected_bare_git_initial_path_vars() {
  local alias_name vars=""
  for alias_name in ${AGENTGUARD_PROTECTED_BARE_GIT_ALIASES:-}; do
    vars="${vars} $alias_name "
  done
  printf '%s' "$vars"
}

_protected_bare_git_launcher() {
  [ -n "${AGENTGUARD_PROTECTED_BARE_GIT_LAUNCHER:-}" ] || return 1
  printf '%s\n' "$AGENTGUARD_PROTECTED_BARE_GIT_LAUNCHER"
}

_protected_bare_git_message() {
  local kind="$1"
  case "$kind" in
    status)
      printf '%s\n' "${AGENTGUARD_PROTECTED_BARE_GIT_STATUS_MESSAGE:-do not run protected bare-Git status with untracked files enabled. Inspect a scoped path with git ls-files --others --exclude-standard -- <path>.}"
      ;;
    ls-files)
      printf '%s\n' "${AGENTGUARD_PROTECTED_BARE_GIT_LS_FILES_MESSAGE:-do not list every untracked file in the protected bare-Git work tree. Use git ls-files --others --exclude-standard -- <path> for a scoped check.}"
      ;;
    clean)
      printf '%s\n' "${AGENTGUARD_PROTECTED_BARE_GIT_CLEAN_MESSAGE:-do not run unscoped git clean in the protected bare-Git work tree. Inspect a scoped path with git clean --dry-run -- <path>.}"
      ;;
  esac
}

# Fast prefilter before paying for the fragment scanner. This intentionally
# accepts false positives: the expensive path is still cheap compared with a
# mistaken untracked walk of a protected bare-Git work tree.
_protected_bare_git_scan_candidate() {
  local text="$1" normalized git_dir git_base alias_name
  _protected_bare_git_configured || return 1

  normalized="${text//\\/}"
  normalized="${normalized//\"/}"
  normalized="${normalized//\'/}"
  git_dir="$(_protected_bare_git_dir)" || return 1
  git_base="${git_dir##*/}"

  if [[ "$text" == *"GIT_DIR="* ||
    "$text" == *"GIT_CONFIG_KEY_"* ||
    "$text" == *"$git_dir"* ||
    "$normalized" == *"GIT_DIR="* ||
    "$normalized" == *"GIT_CONFIG_KEY_"* ||
    "$normalized" == *"$git_dir"* ]]; then
    return 0
  fi
  if [ -n "$git_base" ] &&
    [[ "$text" == *"$git_base"* || "$normalized" == *"$git_base"* ]]; then
    return 0
  fi

  for alias_name in ${AGENTGUARD_PROTECTED_BARE_GIT_ALIASES:-}; do
    [[ "$text" == *"$alias_name"* || "$normalized" == *"$alias_name"* ]] &&
      return 0
  done

  # The hook process can inherit Git environment from the agent shell. If that
  # points at the protected bare repo, raw `git ...` commands need the same
  # guard even when command text does not spell out the repo path.
  if [[ "$normalized" == *git* ]] && [ -n "${GIT_DIR:-}" ] && _is_protected_bare_git_path "$GIT_DIR"; then
    return 0
  fi

  # A configured PATH-visible `git` launcher can make plain `git ...` operate
  # on the protected bare repo. Model that ambient context before the command
  # runs, otherwise `git status -uall` can still walk the whole work tree.
  if [[ "$normalized" == *git* ]] && _protected_bare_git_launcher_dir_context "$PWD"; then
    return 0
  fi

  # Nested shells can refer to exported aliases (`$repo`, `$GIT_DIR`) without
  # spelling the protected path in the child command text.
  [[ -n "${_PROTECTED_BARE_GIT_PATH_VARS:-}" && "$normalized" == *git* ]]
}

# Track just enough assignment state to classify later fragments. Bash would be
# the only complete parser, but the hook must decide before the command runs, so
# this models the variable forms that affect protected bare-Git routing.
_PROTECTED_BARE_GIT_PATH_VARS="$(_protected_bare_git_initial_path_vars)"
declare -A _HOOK_ASSIGNMENTS=()
declare -A _HOOK_EXPORTED_ASSIGNMENTS=()
declare -A _HOOK_READONLY_ASSIGNMENTS=()
declare -A _HOOK_FUNCTION_BODIES=()
_HOOK_CASE_ACTIVE=0
_HOOK_CASE_WORD=""
_HOOK_CASE_MATCHED=0

# Normalize paths lexically only; resolving symlinks here would make the guard
# depend on filesystem state and could turn a cheap classification pass into I/O.
_normalize_path_lexically() {
  local path="$1" part result="" leading_slash=0
  local -a parts=() out=()

  [[ "$path" == /* ]] && leading_slash=1
  IFS=/ read -r -a parts <<<"$path"
  for part in "${parts[@]}"; do
    case "$part" in
      "" | .)
        ;;
      ..)
        if [ "${#out[@]}" -gt 0 ]; then
          unset "out[$((${#out[@]} - 1))]"
          out=("${out[@]}")
        elif [ "$leading_slash" -eq 0 ]; then
          out+=("..")
        fi
        ;;
      *)
        out+=("$part")
        ;;
    esac
  done

  if [ "$leading_slash" -eq 1 ]; then
    result="/"
  fi
  for part in "${out[@]}"; do
    if [ -z "$result" ] || [ "$result" = "/" ]; then
      result="${result}${part}"
    else
      result="${result}/${part}"
    fi
  done

  [ -n "$result" ] || result="."
  printf '%s' "$result"
}

# Alias expansion is deliberately shallow and bounded. Agent commands often use
# `repo=$ALIAS` or `GIT_DIR=$repo`; unbounded shell-like expansion would be both
# slower and riskier than the conservative cases the guard needs.
_expand_path_aliases() {
  local value="$1" name suffix replacement depth
  for ((depth = 0; depth < 6; depth++)); do
    name=""
    suffix=""
    replacement=""

    if [[ "$value" =~ ^\$([A-Za-z_][A-Za-z0-9_]*)(/.*)?$ ]]; then
      name="${BASH_REMATCH[1]}"
      suffix="${BASH_REMATCH[2]:-}"
    elif [[ "$value" =~ ^\$\{([A-Za-z_][A-Za-z0-9_]*)\}(/.*)?$ ]]; then
      name="${BASH_REMATCH[1]}"
      suffix="${BASH_REMATCH[2]:-}"
    else
      break
    fi

    case "$name" in
      HOME)
        replacement="$HOME"
        ;;
      *)
        if [[ -v _HOOK_ASSIGNMENTS[$name] ]]; then
          replacement="${_HOOK_ASSIGNMENTS[$name]}"
        elif [ -n "${!name+x}" ]; then
          replacement="${!name}"
        elif _protected_bare_git_alias_configured "$name"; then
          replacement="$(_protected_bare_git_dir)" || break
        else
          break
        fi
        ;;
    esac

    replacement="$(_strip_outer_quotes "$replacement")"
    replacement="${replacement//\"/}"
    replacement="${replacement//\'/}"
    replacement="${replacement//\\/}"
    value="${replacement}${suffix}"
  done

  printf '%s' "$value"
}

_expand_home_path_token() {
  local value="$1" tilde="~"
  case "$value" in
    "$tilde")
      value="$HOME"
      ;;
    "$tilde"/*)
      value="$HOME/${value#"$tilde"/}"
      ;;
    "\$HOME")
      value="$HOME"
      ;;
    "\$HOME"/*)
      value="$HOME/${value#"\$HOME"/}"
      ;;
    "\${HOME}")
      value="$HOME"
      ;;
    "\${HOME}"/*)
      value="$HOME/${value#"\${HOME}"/}"
      ;;
  esac
  printf '%s' "$value"
}

# The protected bare repo is configured by the integration layer. Agentguard
# only knows that an unscoped untracked scan against this bare work tree is too
# broad to run from an automated hook.
_is_protected_bare_git_path() {
  local value protected
  _protected_bare_git_configured || return 1
  value="$(_strip_outer_quotes "$1")"
  value="${value//\"/}"
  value="${value//\'/}"
  value="${value//\\/}"
  value="$(_expand_path_aliases "$value")"
  value="$(_expand_home_path_token "$value")"
  protected="$(_expand_path_aliases "$(_protected_bare_git_dir)")"
  protected="$(_expand_home_path_token "$protected")"

  while [[ "$value" == */ ]]; do
    value="${value%/}"
  done
  while [[ "$protected" == */ ]]; do
    protected="${protected%/}"
  done
  value="$(_normalize_path_lexically "$value")"
  protected="$(_normalize_path_lexically "$protected")"

  [ "$value" = "$protected" ]
}

_forget_assignment() {
  local name="$1"
  [[ -v _HOOK_READONLY_ASSIGNMENTS[$name] ]] && return 0
  unset "_HOOK_ASSIGNMENTS[$name]"
  unset "_HOOK_EXPORTED_ASSIGNMENTS[$name]"
  _PROTECTED_BARE_GIT_PATH_VARS="${_PROTECTED_BARE_GIT_PATH_VARS// $name / }"
}

_export_assignment() {
  local name="$1"
  if [[ -v _HOOK_ASSIGNMENTS[$name] ]]; then
    _HOOK_EXPORTED_ASSIGNMENTS[$name]="${_HOOK_ASSIGNMENTS[$name]}"
  fi
}

_unexport_assignment() {
  local name="$1"
  unset "_HOOK_EXPORTED_ASSIGNMENTS[$name]"
}

_remember_function_definition() {
  local fragment="$1" name payload

  name="$(_function_definition_name "$fragment")" || return 0
  payload="$(_function_body_payload "$fragment")" || return 0
  _HOOK_FUNCTION_BODIES[$name]="$payload"
}

# Remember assignment effects across fragments so chains like
# `repo=$BARE_HOME_GIT; git --git-dir "$repo" status -uall` are guarded. The
# implementation handles common assignment builtins rather than all Bash syntax;
# unknown forms fail open to normal command execution unless a later fragment is
# clearly a protected bare-Git command.
_remember_protected_bare_git_path_assignments() {
  local fragment="$1" word name value export_assignment=0 unexport_assignment=0 readonly_assignment=0 assignment_builtin=0 unset_builtin=0
  local export_functions=0 unset_variables=1
  local i=0
  local -a words=()

  read -r -a words <<<"$fragment"
  [ "${#words[@]}" -gt 0 ] || return 0

  word="$(_clean_command_word "${words[$i]}")"
  case "$word" in
    export)
      assignment_builtin=1
      export_assignment=1
      ((i++))
      while [ "$i" -lt "${#words[@]}" ]; do
        word="$(_strip_outer_quotes "${words[$i]}")"
        [[ "$word" == -* ]] || break
        [ "$word" = "--" ] && {
          ((i++))
          break
        }
        if [[ "$word" == *n* ]]; then
          export_assignment=0
          unexport_assignment=1
        fi
        if [[ "$word" == *f* ]]; then
          export_assignment=0
          unexport_assignment=0
          export_functions=1
        fi
        ((i++))
      done
      ;;
    readonly)
      assignment_builtin=1
      readonly_assignment=1
      ((i++))
      while [ "$i" -lt "${#words[@]}" ]; do
        word="$(_strip_outer_quotes "${words[$i]}")"
        [[ "$word" == -* ]] || break
        [ "$word" = "--" ] && {
          ((i++))
          break
        }
        ((i++))
      done
      ;;
    declare | typeset)
      assignment_builtin=1
      ((i++))
      while [ "$i" -lt "${#words[@]}" ]; do
        word="$(_strip_outer_quotes "${words[$i]}")"
        [[ "$word" == [-+]* ]] || break
        [ "$word" = "--" ] && {
          ((i++))
          break
        }
        if [[ "$word" == -* ]]; then
          [[ "$word" == *x* ]] && {
            export_assignment=1
            unexport_assignment=0
          }
          [[ "$word" == *r* ]] && readonly_assignment=1
        elif [[ "$word" == +* ]]; then
          [[ "$word" == *x* ]] && {
            export_assignment=0
            unexport_assignment=1
          }
        fi
        ((i++))
      done
      ;;
    unset)
      assignment_builtin=1
      unset_builtin=1
      ((i++))
      while [ "$i" -lt "${#words[@]}" ]; do
        word="$(_strip_outer_quotes "${words[$i]}")"
        [[ "$word" == -* ]] || break
        [ "$word" = "--" ] && {
          ((i++))
          break
        }
        if [[ "$word" == *f* ]]; then
          unset_variables=0
        elif [[ "$word" == *v* ]]; then
          unset_variables=1
        fi
        ((i++))
      done
      ;;
  esac

  while [ "$i" -lt "${#words[@]}" ]; do
    word="${words[$i]}"
    ((i++))
    word="$(_strip_outer_quotes "$word")"
    case "$word" in
      -*)
        [ "$assignment_builtin" -eq 1 ] && continue
        return 0
        ;;
      [A-Za-z_][A-Za-z0-9_]*=*)
        name="${word%%=*}"
        value="${word#*=}"
        if [ "$unset_builtin" -eq 1 ] || [ "$export_functions" -eq 1 ]; then
          continue
        fi
        _remember_assignment "$name" "$value" "$export_assignment" "$readonly_assignment"
        [ "$unexport_assignment" -eq 1 ] && _unexport_assignment "$name"
        ;;
      [A-Za-z_][A-Za-z0-9_]*)
        if [ "$unset_builtin" -eq 1 ]; then
          if [ "$unset_variables" -eq 1 ]; then
            _forget_assignment "$word"
          else
            unset "_HOOK_FUNCTION_BODIES[$word]"
          fi
        elif [ "$export_functions" -eq 1 ]; then
          :
        else
          [ "$export_assignment" -eq 1 ] && _export_assignment "$word"
          [ "$unexport_assignment" -eq 1 ] && _unexport_assignment "$word"
          if [ "$readonly_assignment" -eq 1 ] && [[ -v _HOOK_ASSIGNMENTS[$word] ]]; then
            _HOOK_READONLY_ASSIGNMENTS[$word]=1
          fi
        fi
        [ "$assignment_builtin" -eq 1 ] && continue
        return 0
        ;;
      *)
        return 0
        ;;
    esac
  done
}

_remember_assignment() {
  local name="$1" value="$2" export_assignment="${3:-0}" readonly_assignment="${4:-0}" protected_bare_path=0 expanded_value
  if [[ -v _HOOK_READONLY_ASSIGNMENTS[$name] ]] && [ "$readonly_assignment" -eq 0 ]; then
    return 0
  fi
  expanded_value="$(_expand_path_aliases "$value")"
  _is_protected_bare_git_path "$expanded_value" && protected_bare_path=1

  _HOOK_ASSIGNMENTS[$name]="$expanded_value"
  [ "$readonly_assignment" -eq 1 ] && _HOOK_READONLY_ASSIGNMENTS[$name]=1
  if [ "$export_assignment" -eq 1 ] || [[ -v _HOOK_EXPORTED_ASSIGNMENTS[$name] ]]; then
    _HOOK_EXPORTED_ASSIGNMENTS[$name]="$expanded_value"
  fi

  _PROTECTED_BARE_GIT_PATH_VARS="${_PROTECTED_BARE_GIT_PATH_VARS// $name / }"
  if [ "$protected_bare_path" -eq 1 ]; then
    _PROTECTED_BARE_GIT_PATH_VARS="${_PROTECTED_BARE_GIT_PATH_VARS} $name "
  fi
}

_clean_command_word() {
  local word
  word="$(_shell_word_token "$1")"
  while [[ "$word" == "("* || "$word" == "{"* ]]; do
    word="${word#?}"
  done
  while [[ "$word" == *")" || "$word" == *"}" ]]; do
    word="${word%?}"
  done
  printf '%s' "$word"
}

_word_is_command_prefix() {
  local word
  word="$(_clean_command_word "$1")"
  case "$word" in
    "" | "(" | "{" | "!" | if | then | elif | while | until | do | else | coproc | command | builtin | exec | time | noglob)
      return 0
      ;;
  esac
  return 1
}

_word_is_git_executable() {
  local word
  word="$(_clean_command_word "$1")"
  case "$word" in
    git | */git)
      return 0
      ;;
  esac
  return 1
}

_word_is_env_executable() {
  local word
  word="$(_clean_command_word "$1")"
  case "$word" in
    env | */env)
      return 0
      ;;
  esac
  return 1
}

_word_is_shell_executable() {
  local word
  word="$(_clean_command_word "$1")"
  case "$word" in
    bash | sh | zsh | */bash | */sh | */zsh)
      return 0
      ;;
  esac
  return 1
}

_skip_env_wrapper() {
  local i="$1" word
  shift
  local -a words=("$@")

  _word_is_env_executable "${words[$i]:-}" || return 1
  ((i++))
  while [ "$i" -lt "${#words[@]}" ]; do
    word="$(_clean_command_word "${words[$i]}")"
    case "$word" in
      -u | --unset | -C | --chdir | -S | --split-string)
        i=$((i + 2))
        ;;
      --unset=* | --chdir=* | --split-string=*)
        ((i++))
        ;;
      --)
        ((i++))
        break
        ;;
      -*)
        ((i++))
        ;;
      *)
        break
        ;;
    esac
  done

  printf '%s' "$i"
}

_word_is_privilege_wrapper() {
  local word
  word="$(_clean_command_word "$1")"
  case "$word" in
    sudo | */sudo | doas | */doas)
      return 0
      ;;
  esac
  return 1
}

_sudo_short_option_arg_state() {
  local word="$1" opts c rest
  local i

  opts="${word#-}"
  for ((i = 0; i < ${#opts}; i++)); do
    c="${opts:i:1}"
    case "$c" in
      a | C | c | D | g | h | p | R | r | T | t | U | u)
        rest="${opts:i+1}"
        if [ -n "$rest" ]; then
          printf 'attached'
        else
          printf 'next'
        fi
        return 0
        ;;
    esac
  done
  printf 'none'
}

# `sudo` and `doas` are transparent for blocker intent: `sudo rm -rf /` should
# classify exactly like `rm -rf /`. Skip their wrapper options and environment
# assignments so downstream classifiers see the real command word.
_skip_privilege_wrapper() {
  local i="$1" wrapper word state
  shift
  local -a words=("$@")

  _word_is_privilege_wrapper "${words[$i]:-}" || return 1
  wrapper="$(_clean_command_word "${words[$i]}")"
  wrapper="${wrapper##*/}"
  ((i++))

  while [ "$i" -lt "${#words[@]}" ]; do
    word="$(_clean_command_word "${words[$i]}")"
    case "$word" in
      --)
        ((i++))
        break
        ;;
      -*)
        case "$wrapper:$word" in
          sudo:-a | sudo:-C | sudo:-c | sudo:-D | sudo:-g | sudo:-h | sudo:-p | sudo:-R | sudo:-r | sudo:-T | sudo:-t | sudo:-U | sudo:-u)
            i=$((i + 2))
            ;;
          sudo:--askpass | sudo:--auth-type | sudo:--close-from | sudo:--chdir | sudo:--group | sudo:--host | sudo:--prompt | sudo:--role | sudo:--type | sudo:--command-timeout | sudo:--other-user | sudo:--user)
            i=$((i + 2))
            ;;
          sudo:--askpass=* | sudo:--auth-type=* | sudo:--close-from=* | sudo:--chdir=* | sudo:--group=* | sudo:--host=* | sudo:--prompt=* | sudo:--role=* | sudo:--type=* | sudo:--command-timeout=* | sudo:--other-user=* | sudo:--user=*)
            ((i++))
            ;;
          sudo:-?*)
            state="$(_sudo_short_option_arg_state "$word")"
            case "$state" in
              next)
                i=$((i + 2))
                ;;
              *)
                ((i++))
                ;;
            esac
            ;;
          doas:-u)
            i=$((i + 2))
            ;;
          doas:-u?*)
            ((i++))
            ;;
          *)
            ((i++))
            ;;
        esac
        ;;
      [A-Za-z_][A-Za-z0-9_]*=*)
        ((i++))
        ;;
      *)
        break
        ;;
    esac
  done

  printf '%s' "$i"
}

_word_is_protected_bare_git_launcher() {
  local word="$1" path dir base dir_phys launcher launcher_dir command_path
  word="$(_clean_command_word "$word")"
  launcher="$(_protected_bare_git_launcher)" || return 1

  if [ "$word" = "git" ]; then
    command_path=$(type -P git 2>/dev/null) || return 1
    [ -e "$command_path" ] && [ -e "$launcher" ] &&
      [ "$command_path" -ef "$launcher" ] && return 0
    [ "$command_path" = "$launcher" ]
    return
  fi
  case "$word" in
    */git) ;;
    *) return 1 ;;
  esac

  case "$word" in
    "~"/*)
      path="$HOME/${word#"~/"}"
      ;;
    /*)
      path="$word"
      ;;
    *)
      path="$PWD/$word"
      ;;
  esac

  dir="${path%/*}"
  base="${path##*/}"
  [ "$base" = "git" ] || return 1
  dir_phys=$(_hook_resolve_dir "$PWD" "$dir") || return 1
  launcher_dir=$(_hook_resolve_dir "$PWD" "${launcher%/*}") || return 1
  if [ -e "$path" ] && [ -e "$launcher" ] && [ "$path" -ef "$launcher" ]; then
    return 0
  fi
  [ "$dir_phys/$base" = "$launcher_dir/${launcher##*/}" ]
}

_hook_resolve_dir() {
  local base="$1" path="$2"
  case "$path" in
    "~")
      path="$HOME"
      ;;
    "~"/*)
      path="$HOME/${path#"~/"}"
      ;;
    /*) ;;
    *)
      path="$base/$path"
      ;;
  esac
  (cd -- "$path" 2>/dev/null && pwd -P)
}

_hook_resolve_dir_lexically() {
  local base="$1" path="$2"
  case "$path" in
    "~")
      path="$HOME"
      ;;
    "~"/*)
      path="$HOME/${path#"~/"}"
      ;;
    /*) ;;
    *)
      path="$base/$path"
      ;;
  esac
  path="$(_normalize_path_lexically "$path")"
  [ -d "$path" ] || return 1
  printf '%s' "$path"
}

_protected_bare_git_launcher_dir_context() {
  local dir="$1" dir_phys work_tree_phys root real_git
  _protected_bare_git_configured || return 1
  _protected_bare_git_launcher >/dev/null || return 1
  dir_phys=$(_hook_resolve_dir "$PWD" "$dir") || return 1
  work_tree_phys=$(_hook_resolve_dir "$PWD" "$(_protected_bare_git_work_tree)") || return 1
  case "$dir_phys" in
    "$work_tree_phys" | "$work_tree_phys"/*) ;;
    *) return 1 ;;
  esac

  # Probe normal repos with a non-launcher Git. The launcher may report the
  # protected bare repo, but the question is whether plain `git` will be
  # intercepted because no normal repo owns the target directory.
  if real_git="$(_protected_bare_real_git)"; then
    "$real_git" -C "$dir_phys" rev-parse --show-toplevel >/dev/null 2>&1 &&
      return 1
  fi
  if command -v sl >/dev/null 2>&1; then
    root=$(cd -- "$dir_phys" 2>/dev/null && sl root --config ui.color=never 2>/dev/null) || root=""
    [ -n "$root" ] && { [ -d "$root/.sl" ] || [ -d "$root/.hg" ]; } && return 1
  fi
  return 0
}

_protected_bare_real_git() {
  local launcher candidate
  launcher="$(_protected_bare_git_launcher)" || launcher=""
  while IFS= read -r candidate; do
    [ -x "$candidate" ] || continue
    if [ -n "$launcher" ] && [ -e "$candidate" ] && [ -e "$launcher" ] &&
      [ "$candidate" -ef "$launcher" ]; then
      continue
    fi
    printf '%s\n' "$candidate"
    return 0
  done < <(type -P -a git 2>/dev/null)
  return 1
}

# Decide whether a fragment is operating on the protected bare-Git repo. This
# is narrower than "mentions git": it skips leading env/assignments/command
# wrappers, recognizes explicit protected `GIT_DIR`, and mirrors a configured
# plain `git` launcher for ambient work-tree paths.
_protected_bare_git_context() {
  local fragment="$1"
  local word value git_word="" seen_git_dir=0 explicit_context=0 effective_dir="$PWD" i=0 next_i
  local -a words=()

  read -r -a words <<<"$fragment"
  [ "${#words[@]}" -gt 0 ] || return 1

  while [ "$i" -lt "${#words[@]}" ]; do
    word="$(_clean_command_word "${words[$i]}")"
    case "$word" in
      GIT_DIR=*)
        value="${word#*=}"
        _is_protected_bare_git_path "$value" && seen_git_dir=1
        explicit_context=1
        ((i++))
        continue
        ;;
      GIT_WORK_TREE=*)
        explicit_context=1
        ((i++))
        continue
        ;;
      [A-Za-z_][A-Za-z0-9_]*=*)
        ((i++))
        continue
        ;;
      *)
        if _word_is_command_prefix "$word"; then
          ((i++))
          continue
        fi
        if next_i="$(_skip_env_wrapper "$i" "${words[@]}")"; then
          i="$next_i"
          continue
        fi
        if next_i="$(_skip_privilege_wrapper "$i" "${words[@]}")"; then
          i="$next_i"
          continue
        fi
        ;;
    esac

    _word_is_git_executable "$word" || return 1
    git_word="$word"
    break
  done

  [ "$i" -lt "${#words[@]}" ] || return 1
  _word_is_git_executable "${words[$i]}" || return 1
  git_word="${words[$i]}"
  if [ "$seen_git_dir" -eq 0 ] && value="$(_assignment_value "$fragment" "GIT_DIR")"; then
    explicit_context=1
    _is_protected_bare_git_path "$value" && seen_git_dir=1
  fi
  if value="$(_assignment_value "$fragment" "GIT_WORK_TREE")"; then
    explicit_context=1
  fi

  ((i++))
  while [ "$i" -lt "${#words[@]}" ]; do
    word="$(_shell_word_token "${words[$i]}")"
    case "$word" in
      -C)
        value="$(_shell_word_token "${words[$((i + 1))]:-}")"
        effective_dir=$(_hook_resolve_dir "$effective_dir" "$value") || return 1
        i=$((i + 2))
        continue
        ;;
      -C?*)
        effective_dir=$(_hook_resolve_dir "$effective_dir" "${word#-C}") || return 1
        ((i++))
        continue
        ;;
      --git-dir=*)
        value="${word#*=}"
        _is_protected_bare_git_path "$value" && return 0
        explicit_context=1
        ;;
      --git-dir)
        value="$(_shell_word_token "${words[$((i + 1))]:-}")"
        _is_protected_bare_git_path "$value" && return 0
        explicit_context=1
        ((i++))
        ;;
      --work-tree | --bare)
        explicit_context=1
        ;;
      --work-tree=*)
        explicit_context=1
        ;;
      -c | --config-env | --namespace | --exec-path)
        i=$((i + 2))
        continue
        ;;
      --config-env=* | --namespace=* | --exec-path=*)
        ;;
      --literal-pathspecs | --glob-pathspecs | --noglob-pathspecs | --icase-pathspecs | --no-optional-locks | --no-pager | --paginate)
        ;;
      --)
        break
        ;;
      -*)
        ;;
      *)
        break
        ;;
    esac
    ((i++))
  done

  [ "$seen_git_dir" -eq 1 ] && return 0
  if [ "$explicit_context" -eq 0 ] &&
    _word_is_protected_bare_git_launcher "$git_word" &&
    _protected_bare_git_launcher_dir_context "$effective_dir"; then
    return 0
  fi
  return 1
}

_fragment_command_index() {
  local fragment="$1" word
  local i=0 next_i
  local -a words=()

  while IFS= read -r word; do
    words+=("$word")
  done < <(_fragment_tokens "$fragment")
  [ "${#words[@]}" -gt 0 ] || return 1

  while [ "$i" -lt "${#words[@]}" ]; do
    word="$(_clean_command_word "${words[$i]}")"
    case "$word" in
      [A-Za-z_][A-Za-z0-9_]*=*)
        ((i++))
        ;;
      *)
        if _word_is_command_prefix "$word"; then
          ((i++))
          continue
        fi
        if next_i="$(_skip_env_wrapper "$i" "${words[@]}")"; then
          i="$next_i"
          continue
        fi
        if next_i="$(_skip_privilege_wrapper "$i" "${words[@]}")"; then
          i="$next_i"
          continue
        fi
        printf '%s' "$i"
        return 0
        ;;
    esac
  done

  return 1
}

# Match a command word by basename. This keeps `/bin/rm`, `./git`, and `sl`
# consistent across classifiers without giving hook scripts their own tests.
_word_matches_command() {
  local word="$1" name="$2"
  word="$(_clean_command_word "$word")"
  case "$word" in
    "$name" | */"$name")
      return 0
      ;;
  esac
  return 1
}

# Extract the command word after the same wrappers Bash users commonly reach
# for in hook payloads. Several classifiers share this so their definition of
# "the command" stays aligned.
_fragment_command_word() {
  local fragment="$1" i word
  local -a words=()

  while IFS= read -r word; do
    words+=("$word")
  done < <(_fragment_tokens "$fragment")
  i="$(_fragment_command_index "$fragment")" || return 1
  [ "$i" -lt "${#words[@]}" ] || return 1
  _clean_command_word "${words[$i]}"
}

# Return the first argument after the command word in a fragment, with shell
# quoting and backslashes stripped.  Skips env, assignments, and command
# prefixes using the same walk as _fragment_command_word.
_fragment_first_arg() {
  local fragment="$1" i word
  local -a words=()

  while IFS= read -r word; do
    words+=("$word")
  done < <(_fragment_tokens "$fragment")
  [ "${#words[@]}" -gt 0 ] || return 1
  i="$(_fragment_command_index "$fragment")" || return 1

  # Skip the command word itself
  [ "$i" -lt "${#words[@]}" ] || return 1
  ((i++))
  [ "$i" -lt "${#words[@]}" ] || return 1
  printf '%s' "${words[$i]}"
}

_unescape_nested_shell_text() {
  local text="$1"
  text="${text//\\ / }"
  text="${text//\\;/;}"
  text="${text//\\&/&}"
  text="${text//\\|/|}"
  text="${text//\\(/(}"
  text="${text//\\)/)}"
  printf '%s' "$text"
}

_join_fragment_tokens_from() {
  local start="$1" word result=""
  shift
  local -a words=("$@")

  while [ "$start" -lt "${#words[@]}" ]; do
    word="${words[$start]}"
    if [ -n "$result" ]; then
      result+=" $word"
    else
      result="$word"
    fi
    ((start++))
  done

  [ -n "$result" ] || return 1
  printf '%s\n' "$result"
}

_first_shell_word() {
  local text ch quote="" buf="" escaped=0 started=0
  local i
  text="$(_trim_hook_fragment "$1")"

  for ((i = 0; i < ${#text}; i++)); do
    ch="${text:i:1}"
    if [ "$escaped" -eq 1 ]; then
      buf+="$ch"
      escaped=0
      started=1
      continue
    fi
    if [ "$ch" = "\\" ] && [ "$quote" != "'" ]; then
      escaped=1
      started=1
      continue
    fi
    if [ -n "$quote" ]; then
      if { [ "$quote" = "ansi" ] && [ "$ch" = "'" ]; } ||
        { [ "$quote" != "ansi" ] && [ "$ch" = "$quote" ]; }; then
        quote=""
      else
        buf+="$ch"
      fi
      started=1
      continue
    fi

    case "$ch" in
      "$")
        if [ "${text:i+1:1}" = "'" ]; then
          quote="ansi"
          started=1
          ((i++))
        else
          buf+="$ch"
          started=1
        fi
        ;;
      "'" | '"')
        quote="$ch"
        started=1
        ;;
      [[:space:]])
        [ "$started" -eq 1 ] && break
        ;;
      *)
        buf+="$ch"
        started=1
        ;;
    esac
  done

  [ -n "$buf" ] || return 1
  printf '%s' "$buf"
}

_first_shell_word_with_remainder() {
  local text ch quote="" buf="" escaped=0 started=0 end_index="" tail
  local i j
  text="$(_trim_hook_fragment "$1")"

  for ((i = 0; i < ${#text}; i++)); do
    ch="${text:i:1}"
    if [ "$escaped" -eq 1 ]; then
      buf+="$ch"
      escaped=0
      started=1
      continue
    fi
    if [ "$ch" = "\\" ] && [ "$quote" != "'" ]; then
      escaped=1
      started=1
      continue
    fi
    if [ -n "$quote" ]; then
      if { [ "$quote" = "ansi" ] && [ "$ch" = "'" ]; } ||
        { [ "$quote" != "ansi" ] && [ "$ch" = "$quote" ]; }; then
        quote=""
      else
        buf+="$ch"
      fi
      started=1
      continue
    fi

    case "$ch" in
      "$")
        if [ "${text:i+1:1}" = "'" ]; then
          quote="ansi"
          started=1
          ((i++))
        else
          buf+="$ch"
          started=1
        fi
        ;;
      "'" | '"')
        quote="$ch"
        started=1
        ;;
      [[:space:]])
        if [ "$started" -eq 1 ]; then
          end_index="$i"
          break
        fi
        ;;
      *)
        buf+="$ch"
        started=1
        ;;
    esac
  done

  [ -n "$buf" ] || return 1
  if [ -n "$end_index" ]; then
    j="$end_index"
    while [ "$j" -lt "${#text}" ]; do
      ch="${text:j:1}"
      case "$ch" in
        [[:space:]])
          ((j++))
          ;;
        *)
          break
          ;;
      esac
    done
    tail="${text:j}"
  else
    tail=""
  fi

  if [ -n "$tail" ]; then
    printf '%s %s' "$buf" "$tail"
  else
    printf '%s' "$buf"
  fi
}

# Nested shells hide the dangerous Git operation one quoting layer deeper. We
# only peel the first `-c`/`-lc` payload or eval argument; deeper recursion is
# bounded by the caller so a malicious or accidental command cannot make the
# hook spend arbitrary time parsing.
_nested_shell_payloads() {
  local fragment="$1" command_word word suffix
  local i
  local -a words=()

  while IFS= read -r word; do
    words+=("$word")
  done < <(_fragment_tokens "$fragment")
  i="$(_fragment_command_index "$fragment")" || return 1
  [ "$i" -lt "${#words[@]}" ] || return 1
  command_word="$(_clean_command_word "${words[$i]}")"

  if [ "$command_word" = "eval" ]; then
    ((i++))
    [ "${words[$i]:-}" = "--" ] && ((i++))
    _join_fragment_tokens_from "$i" "${words[@]}"
  elif _word_is_shell_executable "$command_word"; then
    ((i++))
    while [ "$i" -lt "${#words[@]}" ]; do
      word="$(_clean_command_word "${words[$i]}")"
      case "$word" in
        --)
          return 1
          ;;
        -c)
          ((i++))
          [ "$i" -lt "${#words[@]}" ] || return 1
          printf '%s\n' "${words[$i]}"
          return 0
          ;;
        -*)
          # Shells accept compact option clusters such as `bash -ec` and
          # `zsh -fc`; treating the next token as the `-c` payload keeps
          # wrapper spelling from bypassing the shared command classifiers.
          if [[ "$word" == -*c* ]]; then
            suffix="${word#*c}"
            if [ -n "$suffix" ]; then
              printf '%s\n' "$suffix"
            else
              ((i++))
              [ "$i" -lt "${#words[@]}" ] || return 1
              printf '%s\n' "${words[$i]}"
            fi
            return 0
          fi
          ((i++))
          ;;
        *)
          return 1
          ;;
      esac
    done
  fi
}

# `env -S` asks env to split and run a command string. Treat that string like a
# bounded nested payload so wrapper paths cannot hide protected bare-Git scans.
_env_split_payloads() {
  local fragment="$1" word rest payload
  local i=0
  local -a words=()

  read -r -a words <<<"$fragment"
  [ "${#words[@]}" -gt 0 ] || return 1

  while [ "$i" -lt "${#words[@]}" ]; do
    word="$(_clean_command_word "${words[$i]}")"
    case "$word" in
      [A-Za-z_][A-Za-z0-9_]*=*)
        ((i++))
        continue
        ;;
      *)
        if _word_is_command_prefix "$word"; then
          ((i++))
          continue
        fi
        ;;
    esac

    _word_is_env_executable "$word" || return 1
    ((i++))
    break
  done

  while [ "$i" -lt "${#words[@]}" ]; do
    word="$(_clean_command_word "${words[$i]}")"
    case "$word" in
      -S | --split-string)
        case "$fragment" in
          *" $word "*)
            rest="${fragment#*" $word "}"
            ;;
          *)
            return 1
            ;;
        esac
        payload="$(_first_shell_word_with_remainder "$rest")" || return 1
        [ -n "$payload" ] || return 1
        printf '%s\n' "$payload"
        return 0
        ;;
      --split-string=*)
        rest="${fragment#*" --split-string="}"
        payload="$(_first_shell_word_with_remainder "$rest")" || return 1
        [ -n "$payload" ] || return 1
        printf '%s\n' "$payload"
        return 0
        ;;
      -u | --unset | -C | --chdir)
        i=$((i + 2))
        ;;
      --unset=* | --chdir=*)
        ((i++))
        ;;
      --)
        return 1
        ;;
      -*)
        ((i++))
        ;;
      [A-Za-z_][A-Za-z0-9_]*=*)
        ((i++))
        ;;
      *)
        return 1
        ;;
    esac
  done

  return 1
}

_fragment_runs_nested_shell() {
  local command_word
  command_word="$(_fragment_command_word "$1")" || return 1

  [ "$command_word" = "eval" ] && return 0
  _word_is_shell_executable "$command_word" && return 0

  return 1
}

# Return the index of the actual Git subcommand after wrappers and global Git
# options so path names like `status` or grep patterns like `ls-files` don't
# trigger policies by accident.
_git_subcommand_index() {
  local fragment="$1" target="${2:-}" word
  local i
  local -a words=()

  while IFS= read -r word; do
    words+=("$word")
  done < <(_fragment_tokens "$fragment")
  [ "${#words[@]}" -gt 0 ] || return 1

  i="$(_fragment_command_index "$fragment")" || return 1
  [ "$i" -lt "${#words[@]}" ] || return 1
  word="$(_clean_command_word "${words[$i]}")"
  _word_is_git_executable "$word" || return 1
  ((i++))

  while [ "$i" -lt "${#words[@]}" ]; do
    word="$(_clean_command_word "${words[$i]}")"
    case "$word" in
      -C | -c | --git-dir | --work-tree | --namespace | --exec-path)
        i=$((i + 2))
        ;;
      -C?*)
        ((i++))
        ;;
      --git-dir=* | --work-tree=* | --namespace=* | --exec-path=*)
        ((i++))
        ;;
      --bare | --literal-pathspecs | --glob-pathspecs | --noglob-pathspecs | --icase-pathspecs | --no-optional-locks | --no-pager | --paginate)
        ((i++))
        ;;
      --)
        return 1
        ;;
      -*)
        ((i++))
        ;;
      *)
        [ -z "$target" ] || [ "$word" = "$target" ] || return 1
        printf '%s' "$i"
        return 0
        ;;
    esac
  done

  return 1
}

# Identify the actual Git subcommand after wrappers and global Git options.
_git_subcommand_is() {
  _git_subcommand_index "$1" "$2" >/dev/null
}

_git_subcommand_effective_dir() {
  local fragment="$1" target="$2" word value effective_dir="$PWD"
  local i
  local -a words=()

  while IFS= read -r word; do
    words+=("$word")
  done < <(_fragment_tokens "$fragment")
  [ "${#words[@]}" -gt 0 ] || return 1

  i="$(_fragment_command_index "$fragment")" || return 1
  [ "$i" -lt "${#words[@]}" ] || return 1
  word="$(_clean_command_word "${words[$i]}")"
  _word_is_git_executable "$word" || return 1
  ((i++))

  while [ "$i" -lt "${#words[@]}" ]; do
    word="$(_clean_command_word "${words[$i]}")"
    case "$word" in
      -C)
        value="${words[$((i + 1))]:-}"
        effective_dir=$(_hook_resolve_dir_lexically "$effective_dir" "$value") || return 1
        i=$((i + 2))
        ;;
      -C?*)
        value="${word#-C}"
        effective_dir=$(_hook_resolve_dir_lexically "$effective_dir" "$value") || return 1
        ((i++))
        ;;
      -c | --git-dir | --work-tree | --namespace | --exec-path)
        i=$((i + 2))
        ;;
      --git-dir=* | --work-tree=* | --namespace=* | --exec-path=*)
        ((i++))
        ;;
      --bare | --literal-pathspecs | --glob-pathspecs | --noglob-pathspecs | --icase-pathspecs | --no-optional-locks | --no-pager | --paginate)
        ((i++))
        ;;
      --)
        return 1
        ;;
      -*)
        ((i++))
        ;;
      *)
        [ "$word" = "$target" ] || return 1
        printf '%s' "$effective_dir"
        return 0
        ;;
    esac
  done

  return 1
}

_git_subcommand_has_option() {
  local fragment="$1" target="$2" option="$3" word index
  local -a words=()

  while IFS= read -r word; do
    words+=("$word")
  done < <(_fragment_tokens "$fragment")
  index="$(_git_subcommand_index "$fragment" "$target")" || return 1
  index=$((index + 1))

  while [ "$index" -lt "${#words[@]}" ]; do
    word="$(_clean_command_word "${words[$index]}")"
    [ "$word" = "$option" ] && return 0
    ((index++))
  done

  return 1
}

# `git absorb` leaves fixup commits behind unless the caller remembers to run
# the matching autosquash rebase. Keep detection here, next to the other Git
# subcommand classifiers, so wrappers, nested shells, and executable expansion
# contexts all share the same command model.
_git_absorb_command() {
  local text="$1" fragment command_word

  while IFS= read -r fragment; do
    _git_subcommand_is "$fragment" "absorb" && return 0
    command_word="$(_fragment_command_word "$fragment")" || continue
    _word_matches_command "$command_word" "git-absorb" && return 0
  done < <(_hook_executable_fragments "$text")

  return 1
}

_command_subcommand_index() {
  local fragment="$1" command="$2" target="${3:-}" word i
  local -a words=()

  while IFS= read -r word; do
    words+=("$word")
  done < <(_fragment_tokens "$fragment")
  i="$(_fragment_command_index "$fragment")" || return 1
  [ "$i" -lt "${#words[@]}" ] || return 1
  _word_matches_command "${words[$i]}" "$command" || return 1
  ((i++))

  while [ "$i" -lt "${#words[@]}" ]; do
    word="$(_clean_command_word "${words[$i]}")"
    case "$word" in
      --config | --cwd | --repository | -R)
        i=$((i + 2))
        ;;
      --config=* | --cwd=* | --repository=* | -R?*)
        ((i++))
        ;;
      --color | --pager | --encoding)
        i=$((i + 2))
        ;;
      --color=* | --pager=* | --encoding=*)
        ((i++))
        ;;
      --debugger | --encodingmode | --profile | --quiet | --time | --traceback | --verbose | -q | -v)
        ((i++))
        ;;
      --)
        return 1
        ;;
      -*)
        ((i++))
        ;;
      *)
        [ -z "$target" ] || [ "$word" = "$target" ] || return 1
        printf '%s' "$i"
        return 0
        ;;
    esac
  done
  return 1
}

_command_subcommand_is() {
  local fragment="$1" command="$2" target
  shift 2

  for target in "$@"; do
    _command_subcommand_index "$fragment" "$command" "$target" >/dev/null && return 0
  done
  return 1
}

_command_subcommand_has_option() {
  local fragment="$1" command="$2" subcommand="$3" option="$4" word i
  local -a words=()

  while IFS= read -r word; do
    words+=("$word")
  done < <(_fragment_tokens "$fragment")
  i="$(_command_subcommand_index "$fragment" "$command" "$subcommand")" || return 1
  i=$((i + 1))

  while [ "$i" -lt "${#words[@]}" ]; do
    word="$(_clean_command_word "${words[$i]}")"
    [ "$word" = "$option" ] && return 0
    # Many CLIs accept message options with attached values (`-mfoo`,
    # `--message=foo`). Treat those as the same semantic option so metadata-only
    # commit edits do not get mistaken for code-changing commits.
    if [[ "$option" == --* && "$word" == "$option="* ]]; then
      return 0
    fi
    if [[ "$option" == -? && "$word" == "$option"?* ]]; then
      return 0
    fi
    ((i++))
  done
  return 1
}

_rm_target_is_dangerous() {
  local target="$1" home_var="\$HOME" tilde
  tilde=$(printf '\176')
  target="$(_shell_word_token "$target")"

  case "$target" in
    / | '/*' | "$tilde" | "$tilde"/ | "$tilde"'/*' | "$home_var" | "$home_var"/ | "$home_var"'/*' | . | ./ | './*' | .. | ../ | '../*')
      return 0
      ;;
  esac

  { [ "$target" = "$HOME" ] || [ "$target" = "$HOME/" ]; } && return 0
  return 1
}

_rm_fragment_rf_state() {
  local fragment="$1" word i after_options=0 recursive=0 force=0 dangerous=0
  local -a words=()

  while IFS= read -r word; do
    words+=("$word")
  done < <(_fragment_tokens "$fragment")
  i="$(_fragment_command_index "$fragment")" || return 1
  [ "$i" -lt "${#words[@]}" ] || return 1
  _word_matches_command "${words[$i]}" "rm" || return 1
  ((i++))

  while [ "$i" -lt "${#words[@]}" ]; do
    word="$(_clean_command_word "${words[$i]}")"
    if [ "$after_options" -eq 0 ]; then
      case "$word" in
        --)
          after_options=1
          ((i++))
          continue
          ;;
        --recursive)
          recursive=1
          ((i++))
          continue
          ;;
        --force)
          force=1
          ((i++))
          continue
          ;;
        --*)
          ((i++))
          continue
          ;;
        -?*)
          [[ "${word#-}" == *[rR]* ]] && recursive=1
          [[ "${word#-}" == *f* ]] && force=1
          ((i++))
          continue
          ;;
      esac
    fi

    _rm_target_is_dangerous "$word" && dangerous=1
    ((i++))
  done

  [ "$recursive" -eq 1 ] && [ "$force" -eq 1 ] || return 1
  if [ "$dangerous" -eq 1 ]; then
    printf 'block'
  else
    printf 'warn'
  fi
}

_rm_rf_classification() {
  local text="$1" fragment state result=""

  while IFS= read -r fragment; do
    state="$(_rm_fragment_rf_state "$fragment")" || continue
    [ "$state" = "block" ] && {
      printf 'block'
      return 0
    }
    result="warn"
  done < <(_hook_executable_fragments "$text")

  [ "$result" = "warn" ] || return 1
  printf 'warn'
}

_untracked_status_config_value_is_safe() {
  local value
  value="$(_shell_word_token "$1")"
  case "$value" in
    no | false | 0)
      return 0
      ;;
  esac
  return 1
}

# Assignment lookup prefers values in the current fragment, then values learned
# from earlier fragments, then the hook process environment. That order mirrors
# how a shell command line can override inherited state for a single command.
_assignment_value() {
  local fragment="$1" name="$2" word value
  local -a words=()

  read -r -a words <<<"$fragment"
  for word in "${words[@]}"; do
    word="$(_shell_word_token "$word")"
    if [[ "$word" == "$name="* ]]; then
      value="${word#*=}"
      _strip_outer_quotes "$value"
      return 0
    fi
  done

  if [[ -v _HOOK_ASSIGNMENTS[$name] ]]; then
    printf '%s' "${_HOOK_ASSIGNMENTS[$name]}"
    return 0
  fi

  value="${!name-}"
  [ -n "$value" ] || return 1
  printf '%s' "$value"
}

# Git's in-memory config environment can turn untracked status on or off
# without an obvious command-line flag. Treat incomplete config pairs as unsafe:
# a missing value could still mean the real Git invocation lists all untracked
# home-directory files.
_git_config_env_untracked_status_state() {
  local fragment="$1" word value index config_count config_key config_value found=0 state=""
  local -a words=()

  if config_count="$(_assignment_value "$fragment" "GIT_CONFIG_COUNT")" && [[ "$config_count" =~ ^[0-9]+$ ]]; then
    for ((index = 0; index < config_count; index++)); do
      config_key="$(_assignment_value "$fragment" "GIT_CONFIG_KEY_$index")" || continue
      [ "$config_key" = "status.showUntrackedFiles" ] || continue
      found=1
      if config_value="$(_assignment_value "$fragment" "GIT_CONFIG_VALUE_$index")"; then
        if _untracked_status_config_value_is_safe "$config_value"; then
          state="off"
        else
          state="on"
        fi
      else
        state="on"
      fi
    done
    [ "$found" -eq 1 ] || return 1
    printf '%s' "$state"
    return 0
  fi

  read -r -a words <<<"$fragment"
  for word in "${words[@]}"; do
    word="$(_shell_word_token "$word")"
    case "$word" in
      GIT_CONFIG_KEY_*=status.showUntrackedFiles)
        found=1
        value="${word%%=*}"
        index="${value#GIT_CONFIG_KEY_}"
        [[ "$index" =~ ^[A-Za-z0-9_]+$ ]] || {
          state="on"
          continue
        }
        if config_value="$(_assignment_value "$fragment" "GIT_CONFIG_VALUE_$index")"; then
          if _untracked_status_config_value_is_safe "$config_value"; then
            state="off"
          else
            state="on"
          fi
          continue
        fi
        state="on"
        ;;
    esac
  done

  [ "$found" -eq 1 ] || return 1
  printf '%s' "$state"
}

# `git status` has several spellings for untracked behavior (`-uall`,
# `--untracked-files=all`, config overrides, etc.). Return a tri-state as text
# only when a token actually says something about untracked files.
_git_option_untracked_status_state() {
  local fragment="$1" word="$2" value short suffix config_value
  word="$(_shell_word_token "$word")"

  case "$word" in
    status.showUntrackedFiles=*)
      value="${word#*=}"
      value="$(_shell_word_token "$value")"
      if _untracked_status_config_value_is_safe "$value"; then
        printf 'off'
      else
        printf 'on'
      fi
      return 0
      ;;
    --config-env=status.showUntrackedFiles=*)
      value="${word##*=}"
      if config_value="$(_assignment_value "$fragment" "$value")"; then
        if _untracked_status_config_value_is_safe "$config_value"; then
          printf 'off'
        else
          printf 'on'
        fi
      else
        printf 'on'
      fi
      return 0
      ;;
    --untracked*=*)
      value="${word#*=}"
      value="$(_shell_word_token "$value")"
      [ "$value" = "no" ] && {
        printf 'off'
        return 0
      }
      printf 'on'
      return 0
      ;;
    --untracked*)
      printf 'on'
      return 0
      ;;
  esac
  if [[ "$word" == -* && "$word" != --* ]]; then
    short="${word#-}"
    if [[ "$short" == *u* ]]; then
      suffix="${short#*u}"
      [ "$suffix" = "no" ] && {
        printf 'off'
        return 0
      }
      printf 'on'
      return 0
    fi
  fi

  return 1
}

_git_option_ignored_status_state() {
  local word value
  word="$(_shell_word_token "$1")"

  case "$word" in
    --ignored=*)
      value="${word#*=}"
      value="$(_shell_word_token "$value")"
      [ "$value" = "no" ] && {
        printf 'off'
        return 0
      }
      printf 'on'
      return 0
      ;;
    --ignored*)
      printf 'on'
      return 0
      ;;
  esac

  return 1
}

_git_option_lists_others() {
  local word
  word="$(_shell_word_token "$1")"

  case "$word" in
    # Git accepts unique long-option prefixes, so these all mean `--others`.
    # The bracketed spelling preserves the accepted prefix while avoiding a
    # typo-checker false positive on the bare token.
    --o | --ot | --oth | --oth[e] | --other | --others)
      return 0
      ;;
  esac
  [[ "$word" == -* && "$word" != --* && "${word#-}" == *o* ]] && return 0

  return 1
}

# A safe `ls-files --others` check must name real pathspecs after `--`. Root,
# top-level magic, globs, and work-tree aliases are deliberately rejected
# because they can still expand into a full protected bare-Git work-tree walk.
_pathspec_is_specific() {
  local pathspec="$1" tilde="~" home_var="\$HOME"

  case "$pathspec" in
    . | ./ | :*)
      return 1
      ;;
  esac
  [[ "$pathspec" == "$tilde" || "$pathspec" == "$tilde/" ]] && return 1
  [[ "$pathspec" == "$home_var" || "$pathspec" == "$home_var/" ]] && return 1
  [[ "$pathspec" == "$HOME" || "$pathspec" == "$HOME/" ]] && return 1
  [[ "$pathspec" == *"*"* || "$pathspec" == *"?"* || "$pathspec" == *"["* ]] && return 1

  return 0
}

_pathspecs_are_specific() {
  local found=0 pathspec
  while [ "$#" -gt 0 ]; do
    pathspec="$(_shell_word_token "$1")"
    shift
    [ -n "$pathspec" ] || continue
    found=1
    _pathspec_is_specific "$pathspec" || return 1
  done

  [ "$found" -eq 1 ]
}

_git_ls_files_has_scoped_pathspecs() {
  local word
  local -a words=()
  read -r -a words <<<"$1"

  while [ "${#words[@]}" -gt 0 ]; do
    word="$(_shell_word_token "${words[0]}")"
    if [ "$word" = "--" ]; then
      words=("${words[@]:1}")
      _pathspecs_are_specific "${words[@]}"
      return
    fi
    words=("${words[@]:1}")
  done

  return 1
}

_git_status_lists_untracked() {
  local fragment="$1" word option_state untracked_state=0 ignored_state=0
  local -a words=()
  _git_subcommand_is "$fragment" "status" || return 1

  if option_state="$(_git_config_env_untracked_status_state "$fragment")"; then
    [ "$option_state" = "on" ] && untracked_state=1
    [ "$option_state" = "off" ] && untracked_state=0
  fi

  read -r -a words <<<"$fragment"
  for word in "${words[@]}"; do
    if option_state="$(_git_option_untracked_status_state "$fragment" "$word")"; then
      [ "$option_state" = "on" ] && untracked_state=1
      [ "$option_state" = "off" ] && untracked_state=0
    fi
    if option_state="$(_git_option_ignored_status_state "$word")"; then
      [ "$option_state" = "on" ] && ignored_state=1
      [ "$option_state" = "off" ] && ignored_state=0
    fi
  done

  [ "$untracked_state" -eq 1 ] || [ "$ignored_state" -eq 1 ]
}

_git_ls_files_lists_untracked() {
  local fragment="$1" word lists_others=0
  local -a words=()
  _git_subcommand_is "$fragment" "ls-files" || return 1

  read -r -a words <<<"$fragment"
  for word in "${words[@]}"; do
    if _git_option_lists_others "$word"; then
      lists_others=1
      break
    fi
  done

  [ "$lists_others" -eq 1 ] || return 1
  _git_ls_files_has_scoped_pathspecs "$fragment" && return 1
  return 0
}

_git_clean_lists_untracked() {
  local fragment="$1" word
  local -a words=()
  _git_subcommand_is "$fragment" "clean" || return 1

  read -r -a words <<<"$fragment"
  for word in "${words[@]}"; do
    word="$(_shell_word_token "$word")"
    case "$word" in
      -h | --help)
        return 1
        ;;
    esac
  done

  _git_ls_files_has_scoped_pathspecs "$fragment" && return 1
  return 0
}

# Nested executable payloads must be classified with the variable visibility the
# shell would give them, then restored afterward. `bash -c` sees only exported
# variables; command substitutions run in a subshell copy that sees shell-local
# variables too, but neither payload may leak assignments back to the outer
# command sequence.
_block_isolated_protected_bare_git_untracked_scans() {
  local text="$1" depth="$2" inheritance="$3" name saved_paths saved_case_active saved_case_word saved_case_matched
  local -A saved_assignments=() saved_exports=() saved_readonly=() saved_functions=()

  saved_paths="$_PROTECTED_BARE_GIT_PATH_VARS"
  saved_case_active="$_HOOK_CASE_ACTIVE"
  saved_case_word="$_HOOK_CASE_WORD"
  saved_case_matched="$_HOOK_CASE_MATCHED"
  for name in "${!_HOOK_ASSIGNMENTS[@]}"; do
    saved_assignments[$name]="${_HOOK_ASSIGNMENTS[$name]}"
  done
  for name in "${!_HOOK_EXPORTED_ASSIGNMENTS[@]}"; do
    saved_exports[$name]="${_HOOK_EXPORTED_ASSIGNMENTS[$name]}"
  done
  for name in "${!_HOOK_READONLY_ASSIGNMENTS[@]}"; do
    saved_readonly[$name]="${_HOOK_READONLY_ASSIGNMENTS[$name]}"
  done
  for name in "${!_HOOK_FUNCTION_BODIES[@]}"; do
    saved_functions[$name]="${_HOOK_FUNCTION_BODIES[$name]}"
  done

  # Isolated payloads are parsed as their own command stream. Assignment and
  # function state may be inherited, but partial `case` syntax cannot span into
  # command substitutions, nested shells, or structural body scans.
  _HOOK_CASE_ACTIVE=0
  _HOOK_CASE_WORD=""
  _HOOK_CASE_MATCHED=0

  if [ "$inheritance" = "exports" ]; then
    _HOOK_ASSIGNMENTS=()
    _HOOK_READONLY_ASSIGNMENTS=()
    _HOOK_FUNCTION_BODIES=()
    _PROTECTED_BARE_GIT_PATH_VARS="$(_protected_bare_git_initial_path_vars)"
    for name in "${!_HOOK_EXPORTED_ASSIGNMENTS[@]}"; do
      _HOOK_ASSIGNMENTS[$name]="${_HOOK_EXPORTED_ASSIGNMENTS[$name]}"
      _PROTECTED_BARE_GIT_PATH_VARS="${_PROTECTED_BARE_GIT_PATH_VARS// $name / }"
      if _is_protected_bare_git_path "${_HOOK_EXPORTED_ASSIGNMENTS[$name]}"; then
        _PROTECTED_BARE_GIT_PATH_VARS="${_PROTECTED_BARE_GIT_PATH_VARS} $name "
      fi
    done
  fi

  _block_protected_bare_git_untracked_scans "$text" "$depth"

  _HOOK_ASSIGNMENTS=()
  _HOOK_EXPORTED_ASSIGNMENTS=()
  _HOOK_READONLY_ASSIGNMENTS=()
  _HOOK_FUNCTION_BODIES=()
  for name in "${!saved_assignments[@]}"; do
    _HOOK_ASSIGNMENTS[$name]="${saved_assignments[$name]}"
  done
  for name in "${!saved_exports[@]}"; do
    _HOOK_EXPORTED_ASSIGNMENTS[$name]="${saved_exports[$name]}"
  done
  for name in "${!saved_readonly[@]}"; do
    _HOOK_READONLY_ASSIGNMENTS[$name]="${saved_readonly[$name]}"
  done
  for name in "${!saved_functions[@]}"; do
    _HOOK_FUNCTION_BODIES[$name]="${saved_functions[$name]}"
  done
  _PROTECTED_BARE_GIT_PATH_VARS="$saved_paths"
  _HOOK_CASE_ACTIVE="$saved_case_active"
  _HOOK_CASE_WORD="$saved_case_word"
  _HOOK_CASE_MATCHED="$saved_case_matched"
}

_block_nested_protected_bare_git_untracked_scans() {
  _block_isolated_protected_bare_git_untracked_scans "$1" "$2" "exports"
}

_block_subshell_protected_bare_git_untracked_scans() {
  _block_isolated_protected_bare_git_untracked_scans "$1" "$2" "subshell"
}

_block_structural_protected_bare_git_untracked_scans() {
  # Function definitions and case arms are executable regions worth scanning,
  # but assignments inside them do not unconditionally happen before later
  # fragments. Restore the parent assignment model after checking their bodies.
  _block_isolated_protected_bare_git_untracked_scans "$1" "$2" "subshell"
}

_case_pattern_matches_word() {
  local pattern="$1" word="$2"

  case "$pattern" in
    "*")
      return 0
      ;;
    *"|"* | *"["* | *"]"* | *"?"* | *"!"*)
      return 1
      ;;
  esac
  [ "$pattern" = "$word" ]
}

_block_selected_case_arm_protected_bare_git_assignments() {
  local fragment="$1" depth="$2" word pattern payload selected=0
  local -a words=()

  while IFS= read -r word; do
    words+=("$word")
  done < <(_fragment_tokens "$fragment")
  [ "${#words[@]}" -gt 0 ] || return 0

  word="$(_clean_command_word "${words[0]}")"
  if [ "$word" = "esac" ]; then
    _HOOK_CASE_ACTIVE=0
    _HOOK_CASE_WORD=""
    _HOOK_CASE_MATCHED=0
    return 0
  fi

  if [ "$word" = "case" ]; then
    _HOOK_CASE_ACTIVE=0
    _HOOK_CASE_WORD=""
    _HOOK_CASE_MATCHED=0
    [ "${#words[@]}" -ge 4 ] || return 0
    [ "$(_clean_command_word "${words[2]}")" = "in" ] || return 0
    _HOOK_CASE_ACTIVE=1
    _HOOK_CASE_WORD="$(_shell_word_token "${words[1]}")"
    word="${words[3]}"
  elif [ "$_HOOK_CASE_ACTIVE" -eq 1 ]; then
    word="${words[0]}"
  else
    return 0
  fi

  [[ "$word" == *")" ]] || return 0
  pattern="${word%)}"
  pattern="$(_shell_word_token "$pattern")"
  if [ "$_HOOK_CASE_MATCHED" -eq 0 ] &&
    _case_pattern_matches_word "$pattern" "$_HOOK_CASE_WORD"; then
    selected=1
    _HOOK_CASE_MATCHED=1
  fi

  [ "$selected" -eq 1 ] || return 0
  payload="$(_case_arm_payload "$fragment")" || return 0
  [ "$depth" -lt 2 ] || return 0
  # Only the selected arm mutates the surrounding shell. Other arms still get
  # isolated structural scanning for direct dangerous commands, but their
  # assignments must not poison later fragments.
  _block_protected_bare_git_untracked_scans "$payload" $((depth + 1))
}

_block_called_function_protected_bare_git_body() {
  local fragment="$1" depth="$2" command_word payload

  command_word="$(_fragment_command_word "$fragment")" || return 0
  [[ -v _HOOK_FUNCTION_BODIES[$command_word] ]] || return 0
  payload="${_HOOK_FUNCTION_BODIES[$command_word]}"
  [ "$depth" -lt 2 ] || return 0
  # Function bodies execute in the current shell when called. Scan them without
  # restoring assignment state so `f(){ repo=...; }; f; git ...` is modeled like
  # Bash, while mere definitions remain inert until a real call appears.
  _block_protected_bare_git_untracked_scans "$payload" $((depth + 1))
}

_block_protected_bare_git_fragment() {
  local fragment="$1" depth="$2" payload

  _remember_function_definition "$fragment"
  _block_selected_case_arm_protected_bare_git_assignments "$fragment" "$depth"

  # Executable expansions run before the enclosing simple command. Scan them
  # regardless of whether the parent command is itself a protected bare-Git
  # invocation so wrappers like `git --version $(git status -uall)` cannot hide
  # an untracked walk behind an otherwise harmless parent command.
  if [ "$depth" -lt 2 ]; then
    while IFS= read -r -d '' payload; do
      _protected_bare_git_scan_candidate "$payload" && _block_subshell_protected_bare_git_untracked_scans "$payload" $((depth + 1))
    done < <(_executable_expansion_payloads "$fragment")
    while IFS= read -r payload; do
      _protected_bare_git_scan_candidate "$payload" && _block_structural_protected_bare_git_untracked_scans "$payload" $((depth + 1))
    done < <(_structural_shell_payloads "$fragment")
  fi

  if ! _protected_bare_git_context "$fragment"; then
    _block_called_function_protected_bare_git_body "$fragment" "$depth"
    if [ "$depth" -lt 2 ] && _fragment_runs_nested_shell "$fragment"; then
      while IFS= read -r payload; do
        _protected_bare_git_scan_candidate "$payload" && _block_nested_protected_bare_git_untracked_scans "$payload" $((depth + 1))
      done < <(_nested_shell_payloads "$fragment")
    fi
    if [ "$depth" -lt 2 ]; then
      while IFS= read -r payload; do
        _protected_bare_git_scan_candidate "$payload" && _block_nested_protected_bare_git_untracked_scans "$payload" $((depth + 1))
      done < <(_env_split_payloads "$fragment")
    fi
    _remember_protected_bare_git_path_assignments "$fragment"
    return 0
  fi

  if _git_status_lists_untracked "$fragment"; then
    _hook_block "$(_protected_bare_git_message status)"
  elif _git_ls_files_lists_untracked "$fragment"; then
    _hook_block "$(_protected_bare_git_message ls-files)"
  elif _git_clean_lists_untracked "$fragment"; then
    _hook_block "$(_protected_bare_git_message clean)"
  fi
  _remember_protected_bare_git_path_assignments "$fragment"
}

_block_protected_bare_git_line() {
  local line="$1" depth="$2" fragment
  while IFS= read -r fragment; do
    _block_protected_bare_git_fragment "$fragment" "$depth"
  done < <(_split_command_fragments "${line//$'\n'/ }")
}

# Main classifier entry point used by the pre-bash hook.
#
# Contract: this is a bounded, conservative classifier for common executable
# shell forms produced by humans and coding agents. It models enough sequencing,
# assignment/export visibility, nested payloads, functions, case arms, and
# heredoc expansion timing to prevent accidental full-work-tree untracked scans
# against a protected bare-Git repo before they run. It is intentionally not a
# full Bash evaluator: aliases, sourced files, dynamically constructed commands,
# traps, and exotic pattern semantics are outside this hook's scope unless a
# real agent workflow starts producing them.
#
# The scanner walks fragments in order so assignment tracking matches shell
# sequencing. Active heredoc expansions are scanned at their position in the
# command stream: assignments before the heredoc are visible, while assignments
# after it cannot leak backward into the heredoc's command substitutions.
_block_protected_bare_git_untracked_scans() {
  local text="${1:-$AGENTGUARD_CMD_TRIMMED}" depth="${2:-0}" line pending="" marker body="" payload delim strip_tabs active
  local -a heredoc_delims=() heredoc_strips=() heredoc_actives=()

  while IFS= read -r line || [ -n "$line" ]; do
    if [ "${#heredoc_delims[@]}" -gt 0 ]; then
      marker="$line"
      if [ "${heredoc_strips[0]}" -eq 1 ]; then
        while [[ "$marker" == $'\t'* ]]; do
          marker="${marker#$'\t'}"
        done
      fi
      if [ "$marker" = "${heredoc_delims[0]}" ]; then
        if [ "${heredoc_actives[0]}" -eq 1 ] && [ "$depth" -lt 2 ]; then
          # Active heredocs expand as one body just before the receiving command
          # runs. Scanning line-by-line misses `$(` opened on one line and closed
          # on a later one, which is enough to hide a protected bare-Git scan.
          while IFS= read -r -d '' payload; do
            _protected_bare_git_scan_candidate "$payload" && _block_subshell_protected_bare_git_untracked_scans "$payload" $((depth + 1))
          done < <(_flush_active_heredoc_payloads "$body" "${heredoc_actives[0]}")
        fi
        body=""
        heredoc_delims=("${heredoc_delims[@]:1}")
        heredoc_strips=("${heredoc_strips[@]:1}")
        heredoc_actives=("${heredoc_actives[@]:1}")
        continue
      fi
      if [ "${heredoc_actives[0]}" -eq 1 ] && [ "$depth" -lt 2 ]; then
        body="$(_append_heredoc_body_line "$body" "$line")"
      fi
      continue
    fi

    pending="$(_append_pending_command_line "$pending" "$line")"
    if ! _pending_command_complete "$pending"; then
      continue
    fi

    _block_protected_bare_git_line "$pending" "$depth"
    while IFS=$'\t' read -r delim strip_tabs active; do
      [ -n "$delim" ] || continue
      heredoc_delims+=("$delim")
      heredoc_strips+=("$strip_tabs")
      heredoc_actives+=("$active")
    done < <(_heredoc_specs "$pending")
    pending=""
  done <<<"$text"

  if [ "${#heredoc_delims[@]}" -gt 0 ] && [ "$depth" -lt 2 ]; then
    while IFS= read -r -d '' payload; do
      _protected_bare_git_scan_candidate "$payload" && _block_subshell_protected_bare_git_untracked_scans "$payload" $((depth + 1))
    done < <(_flush_active_heredoc_payloads "$body" "${heredoc_actives[0]}")
  fi
  [ -n "$pending" ] && _block_protected_bare_git_line "$pending" "$depth"
}

# ---------------------------------------------------------------------------
# Destructive-operation guards
# ---------------------------------------------------------------------------

# `sudo`/`doas` — agents have no legitimate need for root privilege escalation.
# _fragment_command_word skips privilege wrappers transparently, so check the
# token preamble (everything before the real command index) directly.
_sudo_command() {
  local text="$1" fragment word i cmd_i
  local -a words=()
  while IFS= read -r fragment; do
    words=()
    while IFS= read -r word; do words+=("$word"); done < <(_fragment_tokens "$fragment")
    [ "${#words[@]}" -eq 0 ] && continue
    cmd_i="$(_fragment_command_index "$fragment")" || continue
    for ((i = 0; i < cmd_i; i++)); do
      _word_is_privilege_wrapper "${words[$i]:-}" && return 0
    done
  done < <(_hook_executable_fragments "$text")
  return 1
}

# `git reset --hard` — discards all uncommitted changes without recovery.
_git_reset_hard_command() {
  local text="$1" fragment
  while IFS= read -r fragment; do
    _git_subcommand_has_option "$fragment" "reset" "--hard" && return 0
  done < <(_hook_executable_fragments "$text")
  return 1
}

# `git clean -f` and combined forms (-fd, -df, -fdx, etc.) — deletes untracked
# files. Dry-run (-n/--dry-run) is never matched.
_git_clean_force_command() {
  local text="$1" fragment word i
  local -a words=()
  while IFS= read -r fragment; do
    _git_subcommand_is "$fragment" "clean" || continue
    words=()
    while IFS= read -r word; do words+=("$word"); done < <(_fragment_tokens "$fragment")
    i="$(_git_subcommand_index "$fragment" "clean")" || continue
    i=$((i + 1))
    while [ "$i" -lt "${#words[@]}" ]; do
      word="$(_clean_command_word "${words[$i]}")"
      case "$word" in
        --) break ;;
        --force) return 0 ;;
        -?*) [[ "${word#-}" == *f* ]] && return 0 ;;
      esac
      ((i++))
    done
  done < <(_hook_executable_fragments "$text")
  return 1
}

# `git push --force` / `-f` / `--force-with-lease` — rewrites remote history.
_git_push_force_command() {
  local text="$1" fragment word i
  local -a words=()
  while IFS= read -r fragment; do
    _git_subcommand_is "$fragment" "push" || continue
    words=()
    while IFS= read -r word; do words+=("$word"); done < <(_fragment_tokens "$fragment")
    i="$(_git_subcommand_index "$fragment" "push")" || continue
    i=$((i + 1))
    while [ "$i" -lt "${#words[@]}" ]; do
      word="$(_clean_command_word "${words[$i]}")"
      case "$word" in
        --) break ;;
        --force | --force-with-lease | --force-with-lease=*) return 0 ;;
        -?*) [[ "${word#-}" == *f* ]] && return 0 ;;
      esac
      ((i++))
    done
  done < <(_hook_executable_fragments "$text")
  return 1
}

# Commands that require an interactive TTY and will silently hang an agent turn.
_tty_required_command() {
  local text="$1" fragment command_word
  while IFS= read -r fragment; do
    command_word="$(_fragment_command_word "$fragment")" || continue
    case "$command_word" in
      vim | vi | nvim | view | */vim | */vi | */nvim | */view | \
        nano | pico | joe | micro | */nano | */pico | */joe | */micro | \
        emacs | */emacs | \
        man | info | */man | */info | \
        top | htop | btop | atop | */top | */htop | */btop | */atop | \
        gdb | lldb | */gdb | */lldb | \
        watch | */watch)
        return 0
        ;;
    esac
  done < <(_hook_executable_fragments "$text")
  return 1
}

# Broad process-kill classifier.
#   block — kill PID 1 (init/launchd)
#   warn  — killall or pkill (all matching processes) or kill -9 / SIGKILL
# Accumulates warn across fragments so a later block is never masked.
_broad_kill_classification() {
  local text="$1" fragment command_word word i has_sigkill result=""
  local -a words=()
  while IFS= read -r fragment; do
    command_word="$(_fragment_command_word "$fragment")" || continue

    case "$command_word" in
      killall | */killall | pkill | */pkill)
        result="warn"
        continue
        ;;
    esac

    case "$command_word" in
      kill | */kill) ;;
      *) continue ;;
    esac

    words=()
    while IFS= read -r word; do words+=("$word"); done < <(_fragment_tokens "$fragment")
    i="$(_fragment_command_index "$fragment")" || continue
    i=$((i + 1))
    has_sigkill=0

    while [ "$i" -lt "${#words[@]}" ]; do
      word="$(_clean_command_word "${words[$i]}")"
      case "$word" in
        --) break ;;
        -9 | -KILL | -SIGKILL) has_sigkill=1 ;;
        -s | --signal)
          i=$((i + 1))
          word="$(_clean_command_word "${words[$i]:-}")"
          case "$word" in KILL | SIGKILL | 9) has_sigkill=1 ;; esac
          ;;
        --signal=KILL | --signal=SIGKILL | --signal=9) has_sigkill=1 ;;
        -*) ;;
        1)
          printf 'block'
          return 0
          ;;
      esac
      ((i++))
    done
    [ "$has_sigkill" -eq 1 ] && result="warn"
  done < <(_hook_executable_fragments "$text")
  [ -n "$result" ] || return 1
  printf '%s' "$result"
}

# World-writable chmod modes.
#   block — 777/0777 (world read+write+execute)
#   warn  — 666/0666 or symbolic modes granting world write (o+w, a+w, etc.)
# Accumulates warn across fragments so a later block is never masked.
_chmod_overreach_classification() {
  local text="$1" fragment command_word word i found_mode result=""
  local -a words=()
  while IFS= read -r fragment; do
    command_word="$(_fragment_command_word "$fragment")" || continue
    case "$command_word" in
      chmod | */chmod) ;;
      *) continue ;;
    esac

    words=()
    while IFS= read -r word; do words+=("$word"); done < <(_fragment_tokens "$fragment")
    i="$(_fragment_command_index "$fragment")" || continue
    i=$((i + 1))
    found_mode=0

    while [ "$i" -lt "${#words[@]}" ]; do
      word="$(_clean_command_word "${words[$i]}")"
      case "$word" in
        --) break ;;
        -*) ;;
        *)
          if [ "$found_mode" -eq 0 ]; then
            found_mode=1
            case "$word" in
              777 | 0777)
                printf 'block'
                return 0
                ;;
              666 | 0666)
                result="warn"
                ;;
              *o+w* | *a+w* | *o=rw* | *a=rw*)
                result="warn"
                ;;
            esac
          fi
          ;;
      esac
      ((i++))
    done
  done < <(_hook_executable_fragments "$text")
  [ -n "$result" ] || return 1
  printf '%s' "$result"
}
