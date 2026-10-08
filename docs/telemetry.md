# Audit Telemetry

AgentGuard records an audit trail of what every agent session did: each
prompt, every tool call with its full input and output, each guard decision,
and session lifecycle events. Records are plain JSON files on local disk, kept
per session, readable with `jq`, `rg`, or the `agentguard-telemetry` command.

## Where the logs are

```text
${XDG_STATE_HOME:-~/.local/state}/agentguard/telemetry/
└── sessions/
    └── <agent>/                    claude, codex, gemini, grok, muse, opencode, agent
        └── <session-key>/          the runtime's session id (Claude: the session UUID)
            ├── <epoch-us>-<pid>-telemetry.json   full event payload
            ├── <epoch-us>-<pid>-pre-bash.json    guard decision
            └── ...
```

`agentguard-telemetry dir` prints the root on the current machine. Set
`AGENTGUARD_TELEMETRY_DIR` to an absolute path to relocate it.

The location follows the [XDG Base Directory specification][xdg], which
reserves `XDG_STATE_HOME` for "actions history (logs, history, recently used
files, ...)". It is deliberately not `XDG_RUNTIME_DIR` (where AgentGuard keeps
its ephemeral per-session guard state): the runtime directory is wiped at
logout, and an audit trail must survive that.

For Claude Code the session key is the same UUID that names the transcript under
`~/.claude/projects/<project>/<session-id>.jsonl`, so the two can be read side
by side.

[xdg]: https://specifications.freedesktop.org/basedir-spec/latest/

## Quick start

```bash
agentguard-telemetry sessions               # recent sessions, newest first
agentguard-telemetry sessions --agent codex # one runtime only
agentguard-telemetry show                   # timeline of the latest session
agentguard-telemetry show 8a15fead          # a session by unique key prefix
agentguard-telemetry show current           # the session running this command
agentguard-telemetry show <key> --json | jq # raw records (JSONL)
```

Common audits with `jq` (each record file is one line, so a session directory
concatenates to valid JSONL):

```bash
dir=$(agentguard-telemetry path <key>)

# Every shell command the agent ran, in order
cat "$dir"/*.json | jq -r 'select(.kind=="event" and .event=="PreToolUse")
  | .payload.tool_input.command // empty'

# Every file the agent wrote or edited
cat "$dir"/*.json | jq -r 'select(.kind=="event" and .event=="PreToolUse")
  | .payload.tool_input.file_path // empty' | sort -u

# Everything AgentGuard blocked or warned about, across all sessions
cat "$(agentguard-telemetry dir)"/sessions/*/*/*.json |
  jq -c 'select(.kind=="hook" and (.blocked or .warnings))
    | {ts, agent, session_key, hook, blocked, warnings}'

# The output of a specific tool call
cat "$dir"/*.json | jq 'select(.tool_use_id=="toolu_..." and .event=="PostToolUse")
  | .payload.tool_response'
```

`rg PATTERN "$(agentguard-telemetry dir)"` searches every session's records.

## Record kinds

Two hook entry points write records, and both share one schema.

- **`event`** records come from `agent-hook-telemetry`, a passive recorder that
  integrations register for every event and every tool the runtime exposes.
  They carry the host's complete hook payload under `payload`: prompts, tool
  inputs, tool outputs, permission requests, subagent and compaction events.
- **`hook`** records come from every other `agent-hook-*` entry point. They
  carry that hook's decision: exit status, outcome, block/warning/reminder
  messages, the context it injected into the model, and the command or edit
  files it parsed. They omit the payload because the matching `event` record
  already holds it; join the two on `tool_use_id` (or on `ts` and `event` when
  a runtime has no tool-use id).

A hook records on every exit path, including no-op early exits and fail-closed
parse errors, because recording runs from an `EXIT` trap rather than from the
normal finish path.

## Schema `agentguard.telemetry.v1`

| Field | Kinds | Meaning |
| --- | --- | --- |
| `schema` | all | Always `agentguard.telemetry.v1`. |
| `kind` | all | `event` or `hook`. |
| `ts` | all | RFC 3339 UTC time the hook finished, microsecond precision. |
| `agent` | all | Runtime identity (`AGENTGUARD_NAME` or detection). |
| `session_key` | all | AgentGuard's session key; the directory name. |
| `session_id` | all | The payload's session id when present. |
| `event` | all | Native event name (`PreToolUse`, `BeforeTool`, `SessionStart`, ...). |
| `hook` | all | Executable that wrote the record. |
| `tool_name`, `tool_use_id` | all | From the payload when present. |
| `cwd` | all | Payload `cwd`, else the hook's working directory. |
| `host`, `pid`, `ppid` | all | Where the hook process ran. |
| `exit_status` | all | The status the host received. |
| `outcome` | all | `ok` (0), `blocked` (2), or `error` (anything else). |
| `duration_ms` | all | Hook wall time, including session resolution. |
| `blocked`, `warnings`, `reminders` | hook | Messages the hook emitted, in order. |
| `context` | hook | Model-visible context the hook injected. |
| `command` | hook | Shell command parsed by a Bash guard. |
| `edit_files` | hook | Files parsed by an edit guard. |
| `mcp_server` | hook | Server parsed by an MCP guard. |
| `payload` | event | The raw host payload (parsed JSON, or `{"unparsed": "..."}`). |
| `payload_truncated_chars` | event | Original payload length when truncated. |

Empty and null fields are omitted. Additive fields do not change the schema
version; a renamed or removed field will.

## Configuration

| Variable | Default | Effect |
| --- | --- | --- |
| `AGENTGUARD_TELEMETRY` | `1` | `0`, `false`, `no`, or `off` disables recording. |
| `AGENTGUARD_TELEMETRY_DIR` | XDG state path above | Absolute root override; relative values are ignored. |
| `AGENTGUARD_TELEMETRY_RETENTION_DAYS` | `90` | Sessions idle longer are deleted; `0` keeps everything. |
| `AGENTGUARD_TELEMETRY_MAX_PAYLOAD_CHARS` | `8388608` | Larger payloads keep a prefix and record their length. |

These are read from the hook process environment, which agents inherit from
the shell that launched them. Exporting one inside an agent's tool shell does
not reach hooks.

Retention runs in the background when a session starts, and on demand with
`agentguard-telemetry prune [--days N]`. A session's age is its last activity,
not its start.

## Privacy

Records contain everything the agent saw and did, including file contents and
command output that may hold secrets. The tree is created owner-only (`0700`
directories, `0600` files) and never leaves the machine. Treat it like shell
history: do not commit, sync, or share it without review.

## Coverage

| Runtime | `event` coverage | `hook` decisions |
| --- | --- | --- |
| Claude Code | All tools; prompts, permission requests/denials, tool failures, subagents, compaction, notifications, stop, session start/end | yes |
| Codex | All tools; prompts, permission requests, stop, session start/end | yes |
| Gemini CLI | All tools; agent turns, notifications, session start/end | yes |
| Grok | All tools; prompts, tool failures, subagents, notifications, stop, session start/end | yes |
| Muse | All tools; prompts, stop, session start | yes |
| OpenCode | Not yet: the plugin adapter does not call `agent-hook-telemetry` | yes, for guarded tools |

Events a runtime does not expose to hooks cannot be recorded; for example,
model responses are not hook events in most runtimes. Use the runtime's own
transcript for those.

Consumers that merge the integration fragments pick up the recorder
automatically. A consumer that wires hooks by hand should register
`agent-hook-telemetry` for every event with a match-all matcher.

## Design notes

- **One file per record.** Hosts run matching hooks in parallel, and a large
  record can need several `write(2)` calls, so concurrent appends to one shared
  log could interleave. Each record is written to a private temp file and
  renamed into place, which is atomic and lock-free. Fixed-width microsecond
  filename prefixes make a lexical glob chronological.
- **Payloads travel through stdin.** Linux limits a single argument or
  environment string to 128 KiB, which a tool output easily exceeds.
- **Recording never changes a decision.** Every telemetry failure is silent,
  and the trap preserves the hook's exit status. `agent-hook-telemetry` always
  exits 0 with an empty response, even if an extension tries to block.
