#!/usr/bin/env python3
"""Replay a Muse turn whose reminder side session runs its own tools.

Muse runs a reminder judge as a separate session inside the user's Muse
process. Its hooks carry the root's MUSE_SESSION_ID, so they share the
root's state dir, but their payloads name the side session and no
SubagentStart precedes them. The payloads below mirror a captured Muse
session with ids, paths, model fields and free text replaced. Every hook
runs under this one process, as Muse runs them, so the pane owner is
stable.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

fixture = Path(sys.argv[1])
root = sys.argv[2]
state = Path(os.environ["XDG_RUNTIME_DIR"]) / "agentguard/hook-state" / root
mark = fixture / "muse-side.state"
log = fixture / "muse-side.log"
env = dict(
    os.environ,
    AGENTGUARD_NAME="muse",
    AGENTGUARD_SESSION_ID=root,
    MUSE_SESSION_ID=root,
    AGENTGUARD_TELEMETRY="0",
    TERM_PANE_MARK_STATE=str(mark),
    TERM_PANE_MARK_LOG=str(log),
)
env["PATH"] = str(fixture / "bin") + os.pathsep + env["PATH"]
failures: list[str] = []

ROOT_TURN = "01a1c0d2-0000-7000-8000-00000000a001"
NEXT_TURN = "01a1c0d2-0000-7000-8000-00000000a002"
# One side session per reminder decision; each uses its session id as its
# turn id. The first runs while the approval dialog is open, the others
# after the root's Stop.
SIDE = (
    "01a1c0d2-0000-7000-8000-00000000b001",
    "01a1c0d3-0000-7000-8000-00000000b002",
    "01a1c0d3-0000-7000-8000-00000000b003",
)
CWD = "/work/repo"
BASH_INPUT = {"command": "touch z.txt", "description": "Create z.txt", "workdir": CWD}


def base(session: str, turn: str, event: str) -> dict[str, object]:
    return {
        "cwd": CWD,
        "hook_event_name": event,
        "permission_mode": "default",
        "session_id": session,
        "transcript_path": None,
        "turn_id": turn,
    }


def root_event(event: str, turn: str = ROOT_TURN, **extra: object) -> dict[str, object]:
    payload = base(root, turn, event)
    payload.update(extra)
    return payload


def root_tool(event: str, turn: str = ROOT_TURN) -> dict[str, object]:
    payload = root_event(event, turn, tool_name="bash", tool_input=BASH_INPUT)
    if event != "PermissionRequest":
        payload["tool_use_id"] = "call_root_1"
    if event == "PostToolUse":
        payload["tool_response"] = {"exit_code": 0, "output": ""}
    return payload


def side_tool(event: str, side: str) -> dict[str, object]:
    payload = base(side, side, event)
    payload.update(
        tool_name="submit_reminder_decision",
        tool_input={"decision": "none", "reason": "No reminder applies."},
        tool_use_id="call_side_" + side[-4:],
    )
    if event == "PostToolUse":
        payload["tool_response"] = "reminder decision recorded"
    return payload


def hook(name: str, payload: dict[str, object]) -> None:
    result = subprocess.run(
        [str(fixture / "bin" / ("agent-hook-" + name))],
        input=json.dumps(payload),
        text=True,
        capture_output=True,
        env=env,
        check=False,
    )
    if result.returncode != 0:
        failures.append(f"{name} exited {result.returncode}: {result.stderr.strip()}")


def read(path: Path) -> str | None:
    try:
        return path.read_text(encoding="utf-8").strip()
    except FileNotFoundError:
        return None


def team_root() -> object:
    try:
        return json.loads((state / "busy-team/state.json").read_text(encoding="utf-8")).get("root")
    except (FileNotFoundError, ValueError):
        return None


def lines() -> list[str]:
    return (read(log) or "").splitlines()


def check(condition: bool, message: str) -> None:
    if not condition:
        failures.append(message)


# Root turn: the prompt and the tool that needs approval mark the pane busy.
hook("prompt-submit", root_event("UserPromptSubmit", prompt="Run touch z.txt."))
hook("telemetry", root_tool("PreToolUse"))
hook("telemetry", root_tool("PermissionRequest"))
hook(
    "notification",
    root_event(
        "Notification",
        notification_type="permission_prompt",
        title="Muse needs approval",
        message="repo: waiting for approval",
    ),
)
busy_token = read(mark)
check(bool(busy_token), "root turn did not mark the pane busy")
check(read(state / "attention-sticky") == "waiting root", "root prompt did not raise waiting")
check(team_root() == ROOT_TURN, f"team root is {team_root()!r} before the side session")

# The side session decides while the approval dialog is still open.
before = len(lines())
hook("telemetry", side_tool("PreToolUse", SIDE[0]))
hook("telemetry", side_tool("PostToolUse", SIDE[0]))
check(
    read(state / "attention-sticky") == "waiting root",
    "side session tools cleared the root's waiting mark",
)
check(
    not any("pending" in line for line in lines()[before:]),
    "side session tools touched the pending mark",
)
check(team_root() == ROOT_TURN, f"side session took over the team root: {team_root()!r}")
check(read(mark) == busy_token, "side session tools changed the busy mark")

# The approved tool returns, then the root's Stop ends the turn.
hook("telemetry", root_tool("PostToolUse"))
check(read(state / "attention-sticky") is None, "the approved tool did not clear waiting")
hook("stop", root_event("Stop", stop_hook_active=False))
check(read(mark) is None, "root Stop left the pane busy")
check("--kind done" in (read(Path(str(log) + ".notify")) or ""), "root Stop did not ring done")

# Later side sessions run after the turn ended.
before = len(lines())
for side in SIDE[1:]:
    hook("telemetry", side_tool("PreToolUse", side))
    hook("telemetry", side_tool("PostToolUse", side))
check(read(mark) is None, "side session tools after Stop marked the pane busy again")
check(
    not any(line.startswith("set busy") for line in lines()[before:]),
    "side session tools after Stop called set busy",
)

# The next root turn still marks and clears as before.
hook("prompt-submit", root_event("UserPromptSubmit", NEXT_TURN, prompt="Again."))
check(bool(read(mark)), "next root prompt did not mark the pane busy")
hook("telemetry", root_tool("PreToolUse", NEXT_TURN))
check(team_root() == NEXT_TURN, f"next root tool left team root {team_root()!r}")
hook("stop", root_event("Stop", NEXT_TURN, stop_hook_active=False))
check(read(mark) is None, "next root Stop left the pane busy")

if failures:
    print("\n".join(failures), file=sys.stderr)
    sys.exit(1)
