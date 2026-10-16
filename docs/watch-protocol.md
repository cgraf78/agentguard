# Watch obligations

Pushing a branch or opening a pull request starts checks that run long
after the command returns. An agent that ends its turn there reports work
as done while CI is still running or red. AgentGuard tracks, per agent
session, the work that a separate watcher process should follow to the end,
and the Stop hook reminds (or, opted in, blocks once) when nobody watches it.

AgentGuard does not watch anything itself and never asks a network service.
A *producer* (a watcher such as `git pr-watch --wait` from
[git-tools](https://github.com/cgraf78/git-tools)) publishes small state
files while it watches; AgentGuard only reads them.

## Who owns what

| Part | Owns |
| --- | --- |
| producer (`git pr-watch`) | its domain semantics, the state directory layout, key and scope rules, liveness rules. For pull requests, `git-pr-watch(1)` section STATE FILES is normative. |
| `lib/agentguard/watch.sh` (engine) | obligations, liveness checks, the Stop and pre-bash policy, the session `watch/` layout, `AGENTGUARD_WATCH*`. Keys and scopes are opaque. |
| `lib/agentguard/watch-github.sh` and the post-bash recognizer | the one place that parses `gh pr ...`, `git pr-*`, `git push`, and their output, and maps them onto `git pr-watch` keys and scopes. |
| hook extensions (overlays) | wrapped commands the recognizer cannot see: they call the documented helpers below. |

Kinds of work other than pull requests are *overlay-defined kinds*: an
extension records them with its own producer's tool dir, keys, and hint, and
the engine treats them exactly like pull requests. No engine change is
needed for a new kind.

## Producer state

A producer writes under a state root: an absolute `$XDG_STATE_HOME`, or
`$HOME/.local/state` otherwise, in its *tool dir* (for pull requests,
`git-tools/pr-watch`). The engine reads the union of both candidate roots,
because the hook's environment may differ from the agent shell's.

```text
<root>/<tool dir>/
  watchers/<key>.<pid>            a watcher is following <key>
  watchers/pending.<pid>          a watcher still resolving: every key
  watchers/pending.<scope>.<pid>  the same, for every key with <scope>
  exited/<key>                    "<status> <state> <reason> <epoch>"
  done/<key>                      "<commit> <word> <epoch>"
```

- A *key* names one watched item and a *scope* groups keys (for pull
  requests, `<owner>_<repository>_<number>` and `<owner>_<repository>`,
  lowercased from the URL path). Both use only `A-Z a-z 0-9 . _ -` and are
  compared whole, never split: owners and repository names can contain `_`
  and `.`. The one exception is the push re-arm's same-repository fallback
  below. The host is not part of a pull request's key, so the same
  owner/repository/number on two hosts share one.
- A watcher file's pid is its last `.`-separated field; the name before it
  must equal the key exactly (`<key>.<digits>`). A pending file's scope may
  itself contain `.`.
- Names containing `~` are temporary files and are ignored.
- `done/<key>`: `<word>` is `green`, `merged`, or `closed`. `<epoch>` is when
  the check that judged it started (an epoch of `-` counts as before any
  event). The engine compares that epoch, never the file's mtime, with the
  time it recorded the work: a check that started before a push cannot have
  seen it, and one that started in the same second may not have, so equal
  epochs do not count.
- `exited/<key>` is written when a waiting run ends, for every pull request
  it had resolved, whatever its state (stalls included). Its fourth field is
  the epoch of the check behind the final result the run delivered for the
  pull request (exit status 0, 1, or 8, with it done, needing action, or
  stalled). A run cut short (a signal, an internal error, GitHub unreadable),
  and a pull request still pending when the run ended, get `-`, which counts
  as before any event. The engine reads the second field, the state, and
  that epoch: an exit with state `done` (green or merged) and an epoch
  strictly newer than the key's counts like a newer `done/` record. The
  file's mtime matters only for re-arming an opted-in block (see below).

### Liveness

A watcher or pending file counts only while its pid is alive and that
process's argv[0] or argv[1] has the recorded basename (a script may run as
`bash /path/git-pr-watch ...`). On Linux, argv comes from
`/proc/<pid>/cmdline` with shell builtins; elsewhere from
`ps -o command= -p <pid>`, matched so a path containing spaces still works.
Where a launcher repeats the interpreter, as Termux does
(`bash /path/to/bash git-pr-watch`), a first argument whose basename the
second repeats is skipped and the same rule applied to the rest (twice at
most). A pid reused after a crash therefore does not count.

Per the producer contract, the engine lists `watchers/` before reading
`done/` and `exited/`, and lists it once more when nothing showed, because a
single listing can miss both files while one replaces the other.

### Trust

The engine trusts a path only when every component from the state root to the
file is a real directory or regular file (not a symlink) owned by the current
user (shell `-d`/`-f`, `! -L`, `-O`; no mode check, since producers create
their directories private). A component that exists and fails makes the
tool's state unusable: the engine then enforces nothing for that tool rather
than read it as "no watcher". A missing root, tool dir, or subdirectory just
contributes nothing. With no absolute candidate root at all, nothing is
enforced.

### Producer requirements

A producer that wants AgentGuard to see it must:

- write `watchers/<key>.<pid>` (content: the pid) for as long as it watches,
  and write the watcher files before removing a pending file;
- write `done/<key>` only once the item is really finished, with the epoch of
  the check that judged it;
- write `exited/<key>` as `<status> <state> <reason> <epoch>` when a
  watching run ends, including when it is cut short (before removing its
  watcher files): the engine reads two state words, `done` (a finished
  result, which satisfies the key when its epoch, that of the check behind
  the result, is newer than the key's) and `stall` (with status `8`, a
  reported stall, which never re-arms an opted-in block); every other state
  re-arms a block. The epoch is `-` when the run delivered no final result;
- replace files atomically through names containing `~`, create directories
  private to the user, and never put `~`, `/`, or whitespace in keys or scopes;
- keep its argv[0] or argv[1] basename stable.

## Session state

Under the hook state dir of the session (`$_HOOK_STATE_DIR`, see the README):

```text
watch/<tool-id>/          tool-id = tool dir with "/" replaced by "+"
  tool                    tool dir, watcher argv basename, hint (one line each)
  keys/<key>              "<epoch> <scope>" then the label
  blocked/<key>           the last Stop block for <key> (its mtime)
```

Names never contain `+`, so two tool dirs never share an id.

The session directory is the scope of an obligation: work recorded by one
session is enforced only at that session's Stop. Claude Code subagents share
their parent's session, so a subagent's push is enforced when the parent's
turn ends; a subagent's own Stop enforces nothing.

## Engine behavior

- **Record** (`_hook_watch_record`): a new submit of a key, replacing any
  earlier one. Its epoch is "now".
- **Re-arm** (`_hook_watch_rearm` by scope or `ALL`): new work restarted what
  the watchers follow, so matching recorded keys get a new epoch. Keys whose
  newest `done/` says `merged` or `closed` are skipped; only a per-key re-arm
  (`_hook_watch_rearm_key`) revives them (a reopened pull request).
- **Satisfied**: a live watcher, a matching live pending file (an unscoped
  one matches every key; a scoped one matches keys recorded with exactly that
  scope, so never a key recorded with scope `-`), a `done/` record (green,
  merged, or closed) whose epoch is newer than the key's, or an `exited/`
  record with state `done` (a green or merged result) whose epoch is newer
  than the key's. A red,
  needs-action, stalled, pending, or cut-short exit does not satisfy. All
  epoch comparisons are strict: a check that started in the key's own second
  may not have seen the work.
- **Stop** (foreground only, after extensions): an unsatisfied key gets one
  reminder on stderr per prompt per key and submit, stalls included. With
  `AGENTGUARD_WATCH_BLOCK=1` on Claude Code, a block replaces the reminder
  once per record, re-arm, or watcher exit: it is armed when no block was
  recorded since the key's latest record or re-arm, or when a trusted
  `exited/<key>` is newer (by mtime) than the last block and is not a stall
  the watcher reported (status 8, state `stall`). So a red, needs-action, or
  killed watcher exit re-arms one block (a run killed while the pull request
  was last judged stalled included), a reported stall never re-arms (it
  waits on something outside the pull request, which the agent should
  report rather than restart a watcher for), and any later Stop ends the
  turn. The block message itself carries the Claude Code background advice,
  so it survives a custom hint. Its wording is the pull-request one (push,
  green, stall) for every tool; an overlay-defined kind gets that wording
  with its own labels and hint. Every re-arm needs new work or a new watcher
  run, so blocks stay bounded. An unwritable state dir degrades a block to a
  reminder. Blocks are independent of extension blocks. A `<labels>` token
  in a tool's hint is replaced by the labels the message names.
- **Producer state off**: when the hook environment sets
  `GIT_PR_WATCH_STATE=0` (the variable that turns `git pr-watch`'s state
  files off), the Stop hook says so once per prompt instead of reminding or
  blocking for pull requests.
- **pre-bash**: a `git pr-watch --wait` or `-w` (also `git-pr-watch`, an
  interpreter running its script, or behind setsid, stdbuf, or caffeinate;
  not with `--help`) launched detached (`&`, nohup, setsid, disown) gets a
  warning on every runtime; one launched in the foreground on Claude Code
  without `run_in_background` gets a warning too. Both become blocks under
  `AGENTGUARD_WATCH_BLOCK=1`. Checked first: a watcher chained in one call
  behind a command that records or re-arms (`git push`, a `git pr-*` stack
  or create command, `gh pr create|new|ready|reopen|update-branch`, as in
  `git push && git pr-watch --wait`) gets advice to run that command in the
  foreground and the watcher alone in the background, a block on Claude
  Code under `AGENTGUARD_WATCH_BLOCK=1` and a warning elsewhere: in the
  foreground the watcher dies at the tool timeout, and in the background
  post-bash sees the call before the push or the new pull request exists.
- Everything fails open: unreadable or untrusted state, or an unwritable
  session dir, means less enforcement, never a stuck turn.

### Exits: what satisfies and what re-arms

An opted-in block happens once per submit or watcher exit, with two
refinements. A watcher exit whose last result was green or merged (state
`done`) satisfies the key outright: in a multi-pull-request run, a pull
request that went green early keeps an old `done/` epoch after a later push,
yet the same run goes on judging it and ends with a newer green result. And
a stall exit never re-arms a block: the pull request waits on something
outside it (a review, an approval), so the agent should report the stall
instead of restarting a watcher. A red, needs-action, or killed exit does
re-arm one block, because the agent has something to fix and watch again;
the next Stop ends the turn.

### Settings

Read from the hook environment, which an agent's tool shell cannot change:

| Variable | Effect |
| --- | --- |
| `AGENTGUARD_WATCH=0` | turns recording, re-arming, Stop checks, and launch advice off |
| `AGENTGUARD_WATCH_BLOCK=1` | Stop blocks once per record, re-arm, or non-stall watcher exit (Claude Code), and launch advice blocks |
| `AGENTGUARD_PR_WATCH_HINT` | replaces the pull-request watching advice in the post-bash reminder and the Stop message |

## Pull-request recognition (post-bash)

All of this happens only after a builtin prefilter matched a command in
command position, and only for a successful command (status 0). A call the
host runs in the background (a Claude Code `run_in_background` call, or a
shell Muse reports with `execution_state: "background_running"`) reports
before the command has done anything: it records nothing and re-arms only
through a push, which then re-arms everything (a nuisance re-arm beats a
missed one, and the producer's push-race guard covers an early check).

- **Record**: `gh pr create` or its alias `gh pr new` (not `--dry-run`),
  `git pr-open`, or `git pr-submit` (also the dashed `git-pr-*` forms; not
  `-n`, `--dry-run`, or `--help`), when the command printed a bare
  `https://<host>/<owner>/<repo>/pull/<n>` line (any host) and
  `git-pr-watch` is on `PATH`. The label is the URL.
- **`gh pr ready|reopen|update-branch`**: a URL argument, or `-R`/`--repo`
  `owner/repo` (or `host/owner/repo`) plus a number, re-arms that key; a bare
  number (a leading `#` is ignored) re-arms every recorded key ending in
  `_<n>`; a branch or no argument re-arms everything.
- **Push re-arm**: `git push` (not a dry run, a deletion, or `--help`, and
  not the other non-updating forms the reminder already ignores),
  `git pr-restack`, or `git pr-sync-stack` (not `-n`, `--dry-run`,
  `--no-push`, or `--help`), and only once the session recorded something.
  Its stdout and stderr are parsed:
  - each `To <url>` block (human or porcelain format, `\r` stripped) counts
    only with at least one successful non-tag update line (flags ` `, `+`,
    `*`; `[new tag]` and `refs/tags/` ignored);
  - a block's scope is the URL path's last two components, split on `/` or
    `:` (so `git@alias:owner/repo.git` works), `.git` and trailing `/`
    removed, lowercased;
  - counted scopes that match recorded scopes re-arm those; a counted block
    matching none re-arms recorded scopes ending in `_<repository>` (a fork
    keeps the repository name);
  - with no `To` block and no `Everything up-to-date`, a successful command
    with blank output (a quiet or redirected push or stack command) re-arms
    everything, and so does a `git push` with other output; a stack command
    that printed something else (it said it had nothing to push) re-arms
    nothing;
  - up-to-date, rejected-only, tag-only, and failed pushes re-arm nothing.
- **Reminder**: one per post-bash call. Whenever it recorded or re-armed, it
  recommends `git pr-watch --wait <labels>`, one command per repository
  because the command accepts only pull requests of the checkout it runs in
  (or `AGENTGUARD_PR_WATCH_HINT` instead), every time: each record or re-arm
  is new work. A `<labels>` token in `AGENTGUARD_PR_WATCH_HINT` is replaced
  by the labels here (and by `<pr>` in the general reminder, which knows
  none), as at Stop. Otherwise (nothing recorded or re-armed, or only a push
  summary or URL in the output of an indirect command) the general reminder
  fires once per prompt per command or output: it names
  `AGENTGUARD_PR_WATCH_HINT` when set, else `git pr-watch --wait <pr>` with
  the runtime's background advice when `git-pr-watch` is on `PATH`, else
  `gh pr checks <pr> --repo <owner/repo> --watch --fail-fast`.

## API for hook extensions

Load the helpers with `_hook_load_watch` (engine), `_hook_load_watch_github`
(engine plus GitHub helpers), or `_hook_load_gh_helpers` (GitHub helpers
alone; `_hook_gh_watch_pass` loads the engine when it needs it) from
`hook-helpers.sh`. All functions return instead of exiting and are `set -u`
clean; all but the classifier-based ones (marked Bash 4) run under Bash 3.2.

| Function | Purpose |
| --- | --- |
| `_hook_watch_record <tool-dir> <key> <scope\|-> <argv-basename> <label> <hint>` | record new work; `<hint>` is free text telling the agent how to start a watcher, with an optional `<labels>` token |
| `_hook_watch_rearm <tool-dir> <scope>... \| ALL` | re-arm by scope; prints the labels it re-armed |
| `_hook_watch_rearm_key <tool-dir> <key>` | re-arm one key, reviving a terminal one; prints its label |
| `_hook_watch_list <tool-dir>` | prints `<key> <scope> <terminal\|open>` per recorded key |
| `_hook_watch_collect` | fills `_HOOK_WATCH_UNMET` with `<tool-id> <key>` entries |
| `_hook_watch_claim_block <tool-dir> <key>` | claims the one Stop block per record or re-arm |
| `_hook_watch_launch <option>[\|<option>...] <command> [<subcommand>]` | pre-bash only (needs the command classifier): whether the command runs a watcher with one of the options; sets `_HOOK_WATCH_DETACHED` |
| `_hook_gh_pr_key_scope <url>` | prints `<key> <scope>` for a pull-request URL and sets `_HOOK_GH_PR_KEY`, `_HOOK_GH_PR_SCOPE`, `_HOOK_GH_PR_NUMBER` |
| `_hook_gh_watch_pass <command-text> <output> <status\|-> <background\|-> [<watch-command>]` | Bash 4. The post-bash watch pass, the same code post-bash runs on the agent's own command: judges `<command-text>` (lines of shell) and, for a successful command, records created pull requests from the bare URL lines in `<output>`, re-arms after `gh pr ready\|reopen\|update-branch` and pushes (a push is also parsed with the hook payload's stderr), and reminds as described above. `<status>` and `<background>` (`1` or `0`) may be `-` to read them from the hook payload. `<watch-command>` (default `git pr-watch --wait`) is what the reminders and the stored hint recommend; recording still needs `git-pr-watch` on `PATH`. Fails, doing nothing, when the text runs no command that starts checks. Skips the general reminder when `_HOOK_GH_WATCH_REMINDED` is already set. Sets `_HOOK_GH_WATCH_LABELS` (labels recorded or re-armed), `_HOOK_GH_WATCH_PASS_REMINDED` (this call reminded; reset at entry), and, after any reminder, `_HOOK_GH_WATCH_REMINDED` |
| `_hook_gh_watch_chain <variable>` | pre-bash only (needs the command classifier): stores in the named variable the first command in the hook's command that records or re-arms a pull request (`git push`, `git pr-open\|pr-submit\|pr-restack\|pr-sync-stack`, `gh pr create\|new\|ready\|reopen\|update-branch`) and succeeds; fails when there is none. Lets an extension advise against chaining a watcher behind such a command |
| `_hook_gh_checks_reminder [<watch-command>]` | the general reminder alone (hint, else the watch command when it can run, else `gh pr checks`); sets `_HOOK_GH_WATCH_REMINDED`; callers de-duplicate (see the contract below) |
| `_hook_gh_push_scopes <output> <command>` | prints the recorded scopes a successful push re-arms, `ALL`, or nothing. `<command>` decides two things: a dry-run, delete, `--no-push`, or help word means nothing re-arms, and only a command with a `push` word re-arms `ALL` when it printed output but no `To` block (blank output re-arms `ALL` for any command). Its words are split on whitespace without honoring quotes, so `-o 'x -n'` reads as `-n` |

An extension that runs pull-request commands through a wrapper should hand
the unwrapped commands to the watch pass, which keeps it in step with
post-bash:

```bash
_hook_load_gh_helpers &&
  _hook_gh_watch_pass "$unwrapped" "$_stdout" - - "wrapper watch"
```

The contract with an extension:

- The pass emits its own reminders (the labelled one after a record or
  re-arm, every time; otherwise the general one, once per prompt per
  command text), so the extension adds none of its own for those commands.
- post-bash judges the agent's own command before extensions run, and its
  output-evidence reminder (a push summary or pull-request URL in an
  indirect command's output, which a wrapper prints) runs after them, and
  only when no PR checks reminder was given yet in the hook process: a
  wrapped push gets one reminder, the pass's.
- `_HOOK_GH_WATCH_REMINDED` means the command's reminder is handled: set by
  every PR checks reminder, the base's and the pass's, and by a pass that
  skipped its general reminder as a repeat within the prompt, and never
  reset within the hook process; the pass and post-bash's output path skip
  their general reminder when it is set. `_HOOK_GH_WATCH_PASS_REMINDED` says
  whether the last call itself reminded (reset at entry, unset for such a
  repeat), and
  `_HOOK_GH_WATCH_LABELS` which pull requests it recorded or re-armed.
- A caller of `_hook_gh_checks_reminder` de-duplicates it itself, as post-bash
  does: `_hook_once_per_prompt "pr-checks-<cksum of a stable key>"`, the key
  being `command:<text>` for a command and `output:<evidence lines>` for
  output.

The lower-level helpers remain for other cases. An extension that records
by itself uses `_hook_gh_pr_key_scope` plus:

```bash
_hook_watch_record "$_HOOK_GH_PR_TOOL_DIR" "$_HOOK_GH_PR_KEY" \
  "$_HOOK_GH_PR_SCOPE" "$_HOOK_GH_PR_WATCH_ARGV" "$label" "$hint"
```

One that wraps a push re-arms with the output of `_hook_gh_push_scopes`
passed to `_hook_watch_rearm "$_HOOK_GH_PR_TOOL_DIR"`. An overlay-defined
kind uses its own tool dir, keys (`EXAMPLE-12`, say), scope or `-`, and
watcher basename.

## Documented gaps

- Codex subagents run as their own sessions, so their pushes are enforced at
  their own Stop, not the parent's.
- A producer started through Claude Code's `run_in_background` is not recorded
  as such; only its watcher files count. A pull-request creation run that
  way reports to post-bash before it has run, so it is not recorded, and a
  `gh pr ready|reopen|update-branch` run that way does not re-arm; a push run
  that way re-arms everything.
- A command that fails after pushing or printing a pull-request URL (a
  PostToolUseFailure event) neither records nor re-arms. Muse reports every
  failed command that way (its `error` string carries the result), so
  post-bash never sees a failed Muse command at all.
- A Codex command that outlives the shell tool's `yield_time_ms` keeps
  running as a polled session and gets no PostToolUse, so a long push or
  pull-request creation there neither records nor re-arms.
- On a host without `/proc` and without a `ps` that can report a live
  process's command line, liveness cannot be probed: any watcher file whose
  pid is alive (or, with no `ps` at all, any watcher file) then counts as a
  live watcher (fail open).
- Indirect pushes (a script, or a `git push` mixing deletions and updates in
  one refspec list) do not re-arm; the general reminder still fires on their
  printed summary.
- A renamed repository's push matches neither its recorded scope nor its
  repository part, so it does not re-arm. The repository-part fallback
  compares the scope's tail, so a push to a fork `me/r` also re-arms a
  recorded `alice_my_r` (a nuisance re-arm, never a missed one).
- `gh --repo owner/repo pr ...` (the long option before `pr`) is not
  recognized as a pull-request command; `-R` and `--repo=` are.
- Checks for the same commit reported by another pull request count toward
  `done/` as the producer judges them.
- A custom `XDG_STATE_HOME` that the agent runtime scrubs from the hook
  environment cannot be seen; the engine then reads only
  `$HOME/.local/state`.
- A push to a bare URL (rather than a configured remote) skips the producer's
  push-race guard.
- A re-arm while the producer state cannot be trusted (a symlinked or foreign
  component) cannot tell terminal keys apart, so it re-arms them too; the
  Stop check then enforces nothing for that tool anyway.
- A merged or closed record from an earlier lifetime of a pull request makes
  scope and `ALL` re-arms skip it until a per-key re-arm (such as
  `gh pr reopen <url>`) revives it.
- Same owner, repository, and number on two GitHub hosts share a key.
- The Stop reminder goes to stderr. Claude Code shows a successful Stop's
  stderr only in its transcript view, and the model never sees it; the
  post-bash reminder is the model-visible one. Opt into
  `AGENTGUARD_WATCH_BLOCK=1` for a model-visible Stop.
- A Stop during a watcher's startup, before it has written its pending file,
  sees no watcher.
- Sessions keyed by a process id (runtimes without a session id) can inherit
  an earlier session's records when the id is reused.
- The producer prunes `done/` and `exited/` records after 30 days, so a key
  recorded in a session active longer than that can read as unwatched.
- A symlinked state root, or any symlinked component under it, turns
  enforcement off for the tool (fail open).
- When the producer writes nothing (a sandbox that denies its state dir, or
  `GIT_PR_WATCH_STATE=0` set only in the agent shell, not the hook
  environment), the engine reminds about pull requests it cannot see being
  watched.
- Another session's watcher run satisfies this session's key: the pull
  request was watched, whoever watched it.
- Codex payloads carry no exit status, and a cancelled Muse call with empty
  output reads as status 0, so either can re-arm everything on a quiet push
  or revive a terminal key after a failed `gh pr reopen` (nuisance re-arms,
  never missed ones).
- Localized git translates `[new tag]`, so a localized tag-only push counts as
  a branch update and re-arms (a nuisance re-arm).
- Truncated output (`| head -1`, `| tail -n 3`) can lose the `To` block and
  with it a re-arm.
- Another mention of the watcher on the launch line, in a heredoc or in
  another command (`echo git pr-watch & git pr-watch --wait 12`), can make a
  real foreground launch read as detached (it matters only under
  `AGENTGUARD_WATCH_BLOCK=1`).
- The reminder groups labels by scope, not host, so pull requests of
  same-named repositories on two hosts share one suggested command.
- Launch advice is a heuristic: it does not see a detached watcher inside
  `bash -c '...'` or `{ ...; } &`, and an `&` inside `$(...)` or ANSI-C
  quoting on the launch line can read as backgrounding. A launch line over
  8 KiB is not checked for `&` at all (fail open, to stay inside the
  classification deadline); nohup, setsid, and disown are still seen.
