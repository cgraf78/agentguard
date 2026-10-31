#!/usr/bin/env python3
"""Keep one pane busy while a root or its observed background work runs."""

from __future__ import annotations

import fcntl
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any

SAFE_TOKEN = re.compile(r"^[A-Za-z0-9:._-]{1,256}$")


def mark(action: str, owner: str, token: str) -> bool:
    """Update the owned pane while the state lock still orders hook events."""
    args = ["term-pane-mark", action, "busy", "--owner", owner, "--token", token]
    try:
        result = subprocess.run(
            args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False, timeout=1.5
        )
        if result.returncode == 64:
            # Older providers lack tokens; the lock still orders our writes.
            result = subprocess.run(
                args[:-2],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
                timeout=1.5,
            )
        return result.returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def publish(path: Path, state: dict[str, object]) -> None:
    """Atomically replace private transient state after all fields are ready."""
    fd, name = tempfile.mkstemp(prefix=".state-", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(state, stream, separators=(",", ":"))
            stream.write("\n")
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def child_cache(directory: Path, child: str, turn: str | None) -> None:
    """Publish a cheap first-tool check only after the marker succeeds."""
    cache_path = directory / ("child." + child)
    if turn is None:
        cache_path.unlink(missing_ok=True)
        return
    fd, name = tempfile.mkstemp(prefix=".child-", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write(turn + "\n")
        os.replace(name, cache_path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def owner_alive(owner: str) -> bool:
    """A live newer pane owner outranks a late SessionEnd from an old one."""
    try:
        pid = int(owner)
        if pid <= 0:
            return False
        os.kill(pid, 0)
    except (TypeError, ValueError):
        return False
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def background_tasks(payload: dict[str, object]) -> set[str] | None:
    """Read a parent-scoped in-flight snapshot without trusting display text."""
    tasks = payload.get("background_tasks", payload.get("backgroundTasks"))
    if not isinstance(tasks, list):
        return None
    result = set()
    for task in tasks:
        if not isinstance(task, dict):
            continue
        task_id = task.get("id")
        if (
            task.get("type") == "subagent"
            and isinstance(task_id, str)
            and SAFE_TOKEN.fullmatch(task_id)
        ):
            result.add(task_id)
    return result


# Claude's own terminal task states. Anything else is still alive.
CLAUDE_TERMINAL = ("completed", "failed", "killed")
# Marks Claude state whose children come from SubagentStart/SubagentStop.
CLAUDE_SOURCE = "lifecycle"


def claude_survivors(payload: dict[str, object]) -> tuple[set[str], bool] | None:
    """Return live subagent IDs and whether any live teammate remains.

    A Claude snapshot can only prove a child gone, never working: an idle
    teammate stays "running" until it shuts down. A subagent's task ID is its
    agent ID, but a teammate's is not, so the caller can retire an unlisted
    child only when it is a known subagent or no teammate is alive.
    """
    tasks = payload.get("background_tasks")
    if not isinstance(tasks, list):
        return None
    subagents: set[str] = set()
    teammates = False
    for task in tasks:
        if not isinstance(task, dict) or task.get("status") in CLAUDE_TERMINAL:
            continue
        task_id = task.get("id")
        if task.get("type") == "teammate":
            teammates = True
        elif (
            task.get("type") == "subagent"
            and isinstance(task_id, str)
            and SAFE_TOKEN.fullmatch(task_id)
        ):
            subagents.add(task_id)
    return subagents, teammates


def claude_reconcile(state: dict[str, Any], survivors: tuple[set[str], bool]) -> None:
    """Retire Claude children that a root Stop snapshot proves have ended."""
    live, teammates = survivors
    known = set(state["subagents"])
    kept = {
        child: origin
        for child, origin in state["children"].items()
        if child in live or (child not in known and teammates)
    }
    state["children"] = kept
    # Remember listed subagents, so a later snapshot can retire one even while
    # teammates (which never match by ID) keep unlisted children ambiguous.
    state["subagents"] = sorted((known | live) & kept.keys())


def run() -> int:
    """Apply one root or child transition, then reconcile the pane mark."""
    # The optional last argument is the busy-mark-turn cache key that a live
    # direct mark for the payload's turn leaves (see _hook_busy_turn_token).
    # A team created by a Claude child inherits that root, so the child's Stop
    # cannot end the parent's turn on the pane.
    if len(sys.argv) not in (7, 8) or (
        len(sys.argv) == 8 and not SAFE_TOKEN.fullmatch(sys.argv[7])
    ):
        return 2
    state_dir, session_key, owner, agent, actor, action = sys.argv[1:7]
    root_key = sys.argv[7] if len(sys.argv) == 8 else None
    token = "team:" + session_key
    if (
        not SAFE_TOKEN.fullmatch(token)
        or not owner.isdecimal()
        or agent not in ("codex", "claude", "grok", "muse")
        or actor not in ("root", "child")
    ):
        return 2
    if action not in ("set", "clear", "end", "idle") or (
        action in ("end", "idle") and actor != "root"
    ):
        return 2
    # Only Claude reports that it is idle with no agent working.
    if action == "idle" and agent != "claude":
        return 2
    try:
        payload = json.load(sys.stdin)
        if not isinstance(payload, dict):
            return 2
        turn = (
            payload.get("turn_id")
            if agent in ("codex", "muse")
            else payload.get("prompt_id", payload.get("promptId", "legacy"))
        )
        child = None
        if actor == "child" and agent in ("codex", "claude"):
            child = payload.get("agent_id")
        elif actor == "child" and agent == "muse":
            child = payload.get("child_session_id", payload.get("session_id"))
        if (
            action != "end"
            and actor == "root"
            and (not isinstance(turn, str) or not SAFE_TOKEN.fullmatch(turn))
        ):
            return 2
        if agent in ("codex", "muse") and actor == "child":
            if (
                action not in ("set", "clear")
                or (not isinstance(turn, str) or not SAFE_TOKEN.fullmatch(turn))
                or (not isinstance(child, str) or not SAFE_TOKEN.fullmatch(child))
            ):
                return 2
            if agent == "codex" and (
                not isinstance(payload.get("transcript_path"), str)
                or not payload["transcript_path"]
            ):
                return 2
        if (
            agent == "claude"
            and actor == "child"
            and (
                action not in ("set", "clear")
                or not isinstance(child, str)
                or not SAFE_TOKEN.fullmatch(child)
            )
        ):
            return 2
        if agent == "grok" and actor == "child":
            return 2
        directory = Path(state_dir) / "busy-team"
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        lock_fd = os.open(directory / "lock", os.O_CREAT | os.O_RDWR, 0o600)
        with os.fdopen(lock_fd, "r+") as lock:
            # A failed transition can retry set then clear, each with an
            # older-provider fallback. Let the next event wait through that
            # bounded marker work instead of dropping a child Stop.
            deadline = time.monotonic() + 7.5
            while True:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if time.monotonic() >= deadline:
                        return 1
                    time.sleep(0.01)
            state_path = directory / "state.json"
            fresh = False
            try:
                state = json.loads(state_path.read_text(encoding="utf-8"))
                if not isinstance(state, dict) or not isinstance(state.get("children"), dict):
                    raise ValueError("invalid team state")
            except (OSError, ValueError, json.JSONDecodeError):
                fresh = True
                state = {
                    "root": None,
                    "last_root": None,
                    "children": {},
                    "ended": False,
                    "pending": False,
                }
            # Older releases kept completion tombstones here; nothing reads them.
            state.pop("finished", None)
            if fresh and agent == "claude" and not (actor == "child" and action == "set"):
                # Claude enters team mode only at a child's SubagentStart. Any
                # other event without a team belongs to the direct mark.
                return 1
            if not isinstance(state.get("subagents"), list):
                state["subagents"] = []
            if state.get("ended") and action != "end" and not (actor == "root" and action == "set"):
                return 0  # Late child hooks cannot revive a closed session.
            if (
                action == "end"
                and state.get("owner") not in (None, owner)
                and owner_alive(state["owner"])
            ):
                return 0  # A resumed session belongs to its newer pane owner.
            if not isinstance(state.get("child_started"), dict):
                state["child_started"] = {}
            before = (
                state.get("root"),
                dict(state["children"]),
                state.get("ended"),
                state.get("owner"),
                tuple(state["subagents"]),
                state.get("children_source"),
                dict(state["child_started"]),
            )
            if agent == "claude" and state.get("children_source") != CLAUDE_SOURCE:
                # Older releases recorded every listed teammate as working,
                # keyed by task ID. Those entries never receive a lifecycle
                # Stop, so they would hold the mark until the session ends.
                state["children"] = {}
                state["subagents"] = []
                state["children_source"] = CLAUDE_SOURCE
            if action == "end":
                state = {
                    "root": None,
                    "last_root": None,
                    "children": {},
                    "subagents": [],
                    "children_source": state.get("children_source"),
                    "ended": True,
                    "owner": owner,
                }
            elif actor == "root":
                if action == "set":
                    state["root"] = turn
                    state["last_root"] = turn
                    state["ended"] = False
                    state["owner"] = owner
                    if agent == "muse":
                        # Reap a legacy self-child: no legitimate path
                        # records the session as its own child, and the
                        # entry would retain the mark past every Stop.
                        state["children"].pop(session_key, None)
                else:
                    # Repeated completion for the latest turn can refresh the
                    # parent snapshot. An older Stop cannot replace it after
                    # that newer turn has already completed.
                    owns_turn = state.get("root") == turn or (
                        state.get("root") is None and state.get("last_root") in (None, turn)
                    )
                    if owns_turn:
                        state["root"] = None
                        state["last_root"] = turn
                    if owns_turn and action == "idle":
                        # Claude sends its idle prompt only when the parent is
                        # idle and no subagent or teammate is working, so it
                        # retires children whose Stop never arrived.
                        state["children"] = {}
                        state["subagents"] = []
                    elif owns_turn and agent == "claude":
                        survivors = claude_survivors(payload)
                        if survivors is not None:
                            claude_reconcile(state, survivors)
                    elif owns_turn and agent == "grok":
                        snapshot = background_tasks(payload)
                        if snapshot is not None:
                            state["children"] = {
                                task: state["children"].get(task, turn) for task in snapshot
                            }
                    if owns_turn and agent == "muse":
                        # Self-entries are never legitimate; drop them with
                        # the owning turn instead of retaining the mark.
                        state["children"].pop(session_key, None)
                    if state.get("owner") is None:
                        state["owner"] = owner
            elif agent == "claude":
                # SubagentStart and SubagentStop bracket each child turn,
                # teammates included, and Claude awaits each Stop hook before
                # that child's next turn can start. The child's own snapshot
                # still lists it, so it cannot decide the transition.
                if action == "set":
                    state["children"][child] = turn
                else:
                    state["children"].pop(child, None)
                if state.get("owner") is None:
                    state["owner"] = owner
            elif action == "set":
                if agent == "muse" and child == session_key:
                    pass  # A session cannot be its own child; ignore.
                else:
                    state["children"][child] = turn
            elif state["children"].get(child) == turn:
                del state["children"][child]
            # Each child's latest start lets readers (_hook_child_working)
            # age out a child whose Stop never arrived. Entries leave with
            # their child, whichever transition retired it.
            started = state.get("child_started", {})
            if actor == "child" and action == "set" and child in state["children"]:
                started[child] = int(time.time())
            state["child_started"] = {
                key: value for key, value in started.items() if key in state["children"]
            }
            after = (
                state.get("root"),
                dict(state["children"]),
                state.get("ended"),
                state.get("owner"),
                tuple(state["subagents"]),
                state.get("children_source"),
                dict(state["child_started"]),
            )
            if before == after and not state.get("pending"):
                return 0
            # If the process dies before tmux accepts the mark, the next
            # event retries instead of trusting an incomplete transition.
            was_pending = bool(state.get("pending"))
            state["pending"] = True
            publish(state_path, state)
            if fresh and root_key is not None and not root_key.endswith(":"):
                # Read the parent's turn only after the team is visible. The
                # parent's direct clear removes this cache before it checks for
                # a team, so whichever runs second sees the other's write and
                # the team cannot inherit a turn that already ended.
                try:
                    cached = (Path(state_dir) / "busy-mark-turn").read_text(encoding="utf-8")
                except OSError:
                    cached = ""
                if cached.rstrip("\n") == root_key:
                    state["root"] = turn
                    state["last_root"] = turn
                    publish(state_path, state)
            if was_pending and not state.get("root") and not state["children"]:
                # A failed first team set may have left the previous direct
                # token on the pane. Replace it before clearing the team.
                if not mark("set", owner, token):
                    return 1
            if not mark("set" if state.get("root") or state["children"] else "clear", owner, token):
                return 1
            state["pending"] = False
            if (
                agent == "claude"
                and not state.get("root")
                and not state["children"]
                and not state.get("ended")
            ):
                # An empty Claude team hands the pane back to per-turn direct
                # marks, so a session that once ran a subagent does not pay
                # for this transition on every later turn.
                state_path.unlink(missing_ok=True)
            else:
                publish(state_path, state)
            if action == "end":
                for old_child in before[1]:
                    child_cache(directory, old_child, None)
            elif actor == "child" and agent in ("codex", "muse"):
                child_cache(directory, child, state["children"].get(child))
    except (OSError, TypeError):
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(run())
