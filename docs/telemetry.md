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
        └── <session-key>/          the runtime's own session id (see below)
            ├── <epoch-us>-<pid>-telemetry.json   full event payload
            ├── <epoch-us>-<pid>-pre-bash.json    guard decision
            └── ...
```

`agentguard-telemetry dir` prints the root on the current machine. Set
`AGENTGUARD_TELEMETRY_DIR` to an absolute path to relocate it; an override is
exclusive, so the CLI then reads and prunes only that root. Without one, the
CLI merges the `XDG_STATE_HOME` and `~/.local/state` roots, because some
runtimes scrub `XDG_*` from hook environments.

The location follows the [XDG Base Directory specification][xdg], which
reserves `XDG_STATE_HOME` for "actions history (logs, history, recently used
files, ...)". It is deliberately not `XDG_RUNTIME_DIR` (where AgentGuard keeps
its ephemeral per-session guard state): the runtime directory is wiped at
logout, and an audit trail must survive that.

The session key is the runtime's durable session id, so a session reads as
one timeline and can be matched to the runtime's own transcript:

| Runtime | Session key | Transcript |
| --- | --- | --- |
| Claude Code | Session UUID | `~/.claude/projects/<project>/<session-id>.jsonl`; also `payload.transcript_path` |
| Codex | Thread id (`session_id` in the payload) | `payload.transcript_path` (the rollout file) |
| Gemini CLI | `session_id` from the payload (`GEMINI_SESSION_ID`) | `payload.transcript_path` |
| Grok | `GROK_SESSION_ID`; subagent events stay under the parent session | the runtime's session store |
| Muse | `MUSE_SESSION_ID` (the top-level chat id) | the runtime's session store |
| OpenCode | The plugin's `sessionID` | the runtime's session store |

AgentGuard's guard state is keyed per live process instead (Gemini by its CLI
pid, Grok subagents by a per-child key), which is right for state wiped at
logout but would merge or split sessions over a 90-day retention window.
Where the two differ, each record carries the guard key as `state_key`.

[xdg]: https://specifications.freedesktop.org/basedir-spec/latest/

## Quick start

```bash
agentguard-telemetry sessions               # recent sessions, newest first
agentguard-telemetry sessions --agent codex # one runtime only
agentguard-telemetry show                   # timeline of the latest session
agentguard-telemetry show 8a15fead          # a session by unique key prefix
agentguard-telemetry show current           # the session running this command (*)
agentguard-telemetry show <key> --json | jq # raw records (JSONL)
agentguard-telemetry show all --json        # every session, for cross-session audits
```

(*) `current` resolves the agent session the same way AgentGuard's tool-shell
helpers do: the runtime ids exported to the tool shell (`AGENTGUARD_SESSION_ID`,
Claude, Codex, Grok, Muse, or `GEMINI_SESSION_ID`), then the nearest agent
process for runtimes that export none. It matches either a session key or a
record's `state_key`, so it works from every runtime's tool shell.

Common audits with `jq` (each record file is one line, so `show --json`
prints valid JSONL). The top-level record fields (`event`, `tool_name`,
`tool_use_id`, `session_id`) are normalized from either key spelling, but
their values and the `payload` stay native to each runtime:

| Runtime | Pre/post tool events | Payload keys | Shell tool | Edit tools |
| --- | --- | --- | --- | --- |
| Claude Code, Muse | `PreToolUse` / `PostToolUse` | snake_case | `Bash` | `Edit`, `Write`, ... |
| Codex | `PreToolUse` / `PostToolUse` | snake_case | `Bash` | `apply_patch` (patch in `tool_input.command`) |
| Gemini CLI | `BeforeTool` / `AfterTool` | snake_case | `run_shell_command` | `replace`, `write_file` |
| Grok | `pre_tool_use` / `post_tool_use` | camelCase (`toolInput`) | `Bash`, `run_terminal_command` | `Edit`, `Write`, `search_replace` |
| OpenCode | `PreToolUse` / `PostToolUse` | snake_case (adapter envelope) | `Bash` | `Edit`, `Write`, `MultiEdit` |

The first two recipes read guard decision records, which carry the command
and edit files AgentGuard already parsed, so they work the same on every
runtime. The rest use Claude Code's names; substitute from the table.

```bash
s=<key>   # or: latest, current, a unique prefix

# Every shell command the agent ran, in order (any runtime)
agentguard-telemetry show "$s" --json |
  jq -r 'select(.kind=="hook" and .hook=="agent-hook-pre-bash") | .command'

# Every file the agent wrote or edited (any runtime)
agentguard-telemetry show "$s" --json |
  jq -r 'select(.kind=="hook" and .hook=="agent-hook-pre-edit") | .edit_files[]' |
  sort -u

# Every tool call, including tools no guard inspects (Claude names)
agentguard-telemetry show "$s" --json |
  jq -r 'select(.kind=="event" and .event=="PreToolUse")
    | "\(.ts) \(.tool_name) \(.payload.tool_input | tostring | .[:120])"'

# The output of a specific tool call
agentguard-telemetry show "$s" --json |
  jq 'select(.kind=="event" and .event=="PostToolUse" and .tool_use_id=="toolu_...")
    | .payload.tool_response'

# Everything AgentGuard blocked or warned about, across all sessions
agentguard-telemetry show all --json |
  jq -c 'select(.kind=="hook" and (.blocked or .warnings))
    | {ts, agent, session_key, hook, blocked, warnings}'
```

`rg PATTERN "$(agentguard-telemetry dir)"` searches every session's records.
`agentguard-telemetry dir` prints the root this shell's environment selects;
if a runtime scrubs `XDG_STATE_HOME` from hook processes, its records land in
`~/.local/state` instead, which `sessions` and `show` also search.

## Record kinds

Two hook entry points write records, and both share one schema.

- **`event`** records come from `agent-hook-telemetry`, a passive recorder that
  the integrations register for every tool and for each event listed under
  [Coverage](#coverage).
  They carry the host's complete hook payload under `payload`: prompts, tool
  inputs, tool outputs, permission requests, subagent and compaction events.
- **`hook`** records come from every other `agent-hook-*` entry point. They
  carry that hook's decision: exit status, outcome, block/warning/reminder
  messages, the context it injected into the model, and the command or edit
  files it parsed. They omit the payload because the matching `event` record
  already holds it; join the two on `tool_use_id`. Gemini tool payloads carry
  no call id, and lifecycle events have none anywhere; there, use order: both
  records for an event sit next to each other in the timeline, though
  parallel hooks finish in either order.

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
| `session_key` | all | The durable session key; the directory name. |
| `state_key` | all | AgentGuard's guard-state key, only when it differs from `session_key` (Gemini, Grok subagents). |
| `session_id` | all | The payload's session id when present. |
| `event` | all | The payload's native event name (`PreToolUse`, `BeforeTool`, ...); for a hook that received no payload, AgentGuard's canonical name for that hook. |
| `hook` | all | Executable that wrote the record. |
| `tool_name`, `tool_use_id` | all | From the payload when present (`tool_use_id` also reads `toolUseId`, `toolCallId`, and `call_id`). |
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

Empty and null fields are omitted, except that an `event` record always has
`payload` (null when the host sent none). Additive fields do not change the schema
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
| Claude Code | All tools; prompts, permission requests/denials, tool failures, subagents, compaction, notifications, stop, stop failures, session start/end | yes |
| Codex | All tools; prompts, permission requests, subagents, compaction, interrupts, stop, session start/end | yes |
| Gemini CLI | All tools; agent turns (prompt and response), compression, notifications, session start/end | yes |
| Grok | All tools; prompts, tool failures, subagents, notifications, stop, session start/end | yes |
| Muse | All tools; prompts, permission requests, tool failures, subagents, compaction, notifications, interrupts, stop, stop failures, session start/end | yes |
| OpenCode | Not yet: the plugin adapter does not call `agent-hook-telemetry` | yes, for guarded tools |

Each runtime records every audit-relevant event it exposes, with two
deliberate exclusions everywhere: per-model-call events (Gemini
`BeforeModel`/`AfterModel`/`BeforeToolSelection`, Muse
`PreLLMCall`/`PostLLMCall`), which fire on every request or streamed chunk and
carry the full conversation each time; and configuration or workspace events
(Claude `ConfigChange`, `FileChanged`, worktree events, and similar) that do
not describe what the agent did. Use the runtime's own transcript for model
traffic. Grok's event list could not be verified beyond the events above, so
any further Grok events are not wired yet. Wiring one means adding it to the
runtime's fragment after confirming the runtime accepts it.

Codex only runs hooks whose trust hash has been approved, and an untrusted
handler is skipped without an error: `sessions --agent codex` simply stays
empty, including for headless `codex exec`. Approve the AgentGuard handlers
when Codex asks to review new hooks, or let the configuration manager that
installs the fragment record their trust. Every new or changed handler needs
approval once, including each event added to the fragment.

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
