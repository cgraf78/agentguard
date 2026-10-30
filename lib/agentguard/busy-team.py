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


def background_tasks(payload: dict[str, object], agent: str) -> set[str] | None:
    """Read a parent-scoped in-flight snapshot without trusting display text."""
    tasks = payload.get("background_tasks", payload.get("backgroundTasks"))
    if not isinstance(tasks, list):
        return None
    result = set()
    team_types = ("subagent", "teammate") if agent == "claude" else ("subagent",)
    for task in tasks:
        if not isinstance(task, dict):
            continue
        task_id = task.get("id")
        task_type = task.get("type")
        if task_type in team_types and isinstance(task_id, str) and SAFE_TOKEN.fullmatch(task_id):
            result.add(task_id)
    return result


def run() -> int:
    """Apply one root or child transition, then reconcile the pane mark."""
    if len(sys.argv) != 7:
        return 2
    state_dir, session_key, owner, agent, actor, action = sys.argv[1:]
    token = "team:" + session_key
    if (
        not SAFE_TOKEN.fullmatch(token)
        or not owner.isdecimal()
        or agent not in ("codex", "claude", "grok", "muse")
        or actor not in ("root", "child")
    ):
        return 2
    if action not in ("set", "clear", "end") or (action == "end" and actor != "root"):
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
        if actor == "child" and agent == "codex":
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
        if (agent == "claude" and actor == "child" and action != "clear") or (
            agent == "grok" and actor == "child"
        ):
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
            try:
                state = json.loads(state_path.read_text(encoding="utf-8"))
                if not isinstance(state, dict) or not isinstance(state.get("children"), dict):
                    raise ValueError("invalid team state")
            except (OSError, ValueError, json.JSONDecodeError):
                state = {
                    "root": None,
                    "last_root": None,
                    "children": {},
                    "finished": [],
                    "ended": False,
                    "pending": False,
                }
            if not isinstance(state.get("finished"), list):
                state["finished"] = []
            if state.get("ended") and action != "end" and not (actor == "root" and action == "set"):
                return 0  # Late child hooks cannot revive a closed session.
            if (
                action == "end"
                and state.get("owner") not in (None, owner)
                and owner_alive(state["owner"])
            ):
                return 0  # A resumed session belongs to its newer pane owner.
            before = (
                state.get("root"),
                dict(state["children"]),
                state.get("ended"),
                state.get("owner"),
                tuple(state["finished"]),
            )
            if action == "end":
                state = {
                    "root": None,
                    "last_root": None,
                    "children": {},
                    "finished": [],
                    "ended": True,
                    "owner": owner,
                }
            elif actor == "root":
                if action == "set":
                    state["root"] = turn
                    state["last_root"] = turn
                    state["ended"] = False
                    state["owner"] = owner
                    if agent == "claude" and payload.get("hook_event_name") == "UserPromptSubmit":
                        # A later user request can resume an existing task
                        # ID. Keep tombstones only within one request.
                        state["finished"] = []
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
                    if owns_turn and agent in ("claude", "grok"):
                        snapshot = background_tasks(payload, agent)
                        if snapshot is not None:
                            if agent == "claude":
                                state["finished"] = sorted(
                                    set(state["finished"]) | (state["children"].keys() - snapshot)
                                )
                            state["children"] = {
                                task: state["children"].get(task, turn)
                                for task in snapshot
                                if task not in state["finished"]
                            }
                    if state.get("owner") is None:
                        state["owner"] = owner
            elif agent == "claude":
                # Claude includes the parent prompt on child callbacks. A
                # delayed child completion from an older prompt must not
                # replace a newer parent snapshot.
                snapshot = background_tasks(payload, agent)
                if snapshot is not None:
                    # A new request can resume a task ID without a root Stop
                    # snapshot. Finished IDs from this request stay fenced
                    # against delayed child callbacks.
                    if turn == state.get("last_root"):
                        for task in snapshot - set(state["finished"]):
                            state["children"].setdefault(task, turn)
                    # An older prompt may clear only its own missing tasks.
                    missing = {
                        task
                        for task, origin in state["children"].items()
                        if task not in snapshot
                        and (turn == state.get("last_root") or origin == turn)
                    }
                    state["finished"] = sorted(set(state["finished"]) | missing)
                    for task in missing:
                        del state["children"][task]
            elif action == "set":
                state["children"][child] = turn
            elif state["children"].get(child) == turn:
                del state["children"][child]
            after = (
                state.get("root"),
                dict(state["children"]),
                state.get("ended"),
                state.get("owner"),
                tuple(state["finished"]),
            )
            if before == after and not state.get("pending"):
                return 0
            # If the process dies before tmux accepts the mark, the next
            # event retries instead of trusting an incomplete transition.
            was_pending = bool(state.get("pending"))
            state["pending"] = True
            publish(state_path, state)
            if was_pending and not state.get("root") and not state["children"]:
                # A failed first team set may have left the previous direct
                # token on the pane. Replace it before clearing the team.
                if not mark("set", owner, token):
                    return 1
            if not mark("set" if state.get("root") or state["children"] else "clear", owner, token):
                return 1
            state["pending"] = False
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
