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
  as before any event. The engine reads only that epoch, never the file's
  mtime: an epoch strictly newer than the key's means the pull request was
  watched after the work and its result delivered, whatever its final state.

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
- write `exited/<key>` when a watching run ends (before removing its watcher
  files), with the epoch of the check behind the result it delivered, or `-`
  when it delivered none;
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
  scope, so never a key recorded with scope `-`), a `done/` record whose
  epoch is newer than the key's, or an `exited/` record whose result epoch is
  newer than the key's. All epoch comparisons are strict: a check that
  started in the key's own second may not have seen the work.
- **Stop** (foreground only, after extensions): an unsatisfied key gets one
  reminder on stderr per prompt per key and submit. With
  `AGENTGUARD_WATCH_BLOCK=1` on Claude Code, the first Stop after a record or
  re-arm blocks instead (once), naming the keys; any later Stop ends the
  turn. An unwritable state dir degrades a block to a reminder. Blocks are
  independent of extension blocks. A `<labels>` token in a tool's hint is
  replaced by the labels the message names.
- **Producer state off**: when the hook environment sets
  `GIT_PR_WATCH_STATE=0` (the variable that turns `git pr-watch`'s state
  files off), the Stop hook says so once per prompt instead of reminding or
  blocking for pull requests.
- **pre-bash**: a `git pr-watch --wait` or `-w` (also `git-pr-watch`, an
  interpreter running its script, or behind setsid, stdbuf, or caffeinate;
  not with `--help`) launched detached (`&`, nohup, setsid, disown) gets a
  warning on every runtime; one launched in the foreground on Claude Code
  without `run_in_background` gets a warning too. Both become blocks under
  `AGENTGUARD_WATCH_BLOCK=1`.
- Everything fails open: unreadable or untrusted state, or an unwritable
  session dir, means less enforcement, never a stuck turn.

### Why an exited watcher satisfies

The original design counted only a live watcher or a newer `done/` record,
and re-armed an opted-in block on every watcher exit. That looped: a pull
request with a conflict or a persistent failure makes the watcher exit at
once, the next Stop blocked again with "not watched", the agent re-ran the
watcher, and so on, although the agent already had the result. In a
multi-pull-request run, a pull request that went green early kept its old
`done/` epoch after a later push, so it read as unwatched although the same
run went on judging it. An obligation exists to stop an agent walking away
without watching at all, so a watcher that delivered a result after the
work (its `exited/` epoch) now satisfies it, whatever the result, and a
block happens once per record or re-arm.

### Settings

Read from the hook environment, which an agent's tool shell cannot change:

| Variable | Effect |
| --- | --- |
| `AGENTGUARD_WATCH=0` | turns recording, re-arming, Stop checks, and launch advice off |
| `AGENTGUARD_WATCH_BLOCK=1` | Stop blocks once per record or re-arm (Claude Code), and launch advice blocks |
| `AGENTGUARD_PR_WATCH_HINT` | replaces the pull-request watching advice in the post-bash reminder and the Stop message |

## Pull-request recognition (post-bash)

All of this happens only after a builtin prefilter matched a command in
command position, and only for a successful command (status 0) that the host
did not run in the background (a Claude Code `run_in_background` call, or a
shell Muse reports with `execution_state: "background_running"`, reports
before the command has done anything):

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
  is new work. Otherwise the general PR checks reminder is unchanged,
  including its once-per-prompt de-duplication.

## API for hook extensions

Load the helpers with `_hook_load_watch` (engine) or `_hook_load_watch_github`
(engine plus GitHub helpers) from `hook-helpers.sh`. All functions return
instead of exiting, run under Bash 3.2, and are `set -u` clean.

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
| `_hook_gh_push_scopes <output> <command>` | prints the recorded scopes a successful push re-arms, `ALL`, or nothing. `<command>` decides two things: a dry-run, delete, `--no-push`, or help word means nothing re-arms, and only a command with a `push` word re-arms `ALL` when it printed output but no `To` block (blank output re-arms `ALL` for any command). Its words are split on whitespace without honoring quotes, so `-o 'x -n'` reads as `-n` |

An extension that wraps pull-request creation records with
`_hook_gh_pr_key_scope` plus:

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
  as such; only its watcher files count. A pull-request creation or push run
  that way reports to post-bash before it has run, so it neither records nor
  re-arms.
- A command that fails after pushing or printing a pull-request URL (a
  PostToolUseFailure event) neither records nor re-arms. Muse reports every
  failed command that way (its `error` string carries the result), so
  post-bash never sees a failed Muse command at all.
- A Codex command that outlives the shell tool's `yield_time_ms` keeps
  running as a polled session and gets no PostToolUse, so a long push or
  pull-request creation there neither records nor re-arms.
- On a host without `/proc` and without `ps`, liveness cannot be probed:
  any watcher file then counts as a live watcher (fail open).
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
