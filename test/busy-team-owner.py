#!/usr/bin/env python3
"""Prove a late old SessionEnd cannot erase a resumed pane's team mark."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from pathlib import Path

fixture = Path(sys.argv[1])
session = sys.argv[2]
state_dir = fixture / "owner-state"
pane_state = fixture / "owner-pane.state"
env = dict(os.environ, TERM_PANE_MARK_STATE=str(pane_state))
env["TERM_PANE_MARK_LOG"] = str(fixture / "owner-pane.log")
env["PATH"] = str(fixture / "bin") + os.pathsep + env["PATH"]
script = Path(sys.argv[3])
current_owner = str(os.getpid())
old_owner = "99999999"  # Above Linux's maximum PID; the old process has exited.


def transition(owner: str, action: str, turn: str) -> None:
    """Call the real state transition with a fixed synthetic pane owner."""
    result = subprocess.run(
        ["python3", str(script), str(state_dir), session, owner, "codex", "root", action],
        input=json.dumps({"session_id": session, "turn_id": turn}),
        text=True,
        capture_output=True,
        env=env,
        check=False,
    )
    assert result.returncode == 0, (action, result.returncode, result.stderr)


transition(old_owner, "set", "old")
transition(current_owner, "set", "new")
transition(old_owner, "end", "old")
assert pane_state.exists(), "old SessionEnd cleared the resumed team"
transition(current_owner, "end", "new")
assert not pane_state.exists(), "current SessionEnd did not clear its team"

contended_dir = fixture / "contended-state"
contended_pane = fixture / "contended-pane.state"
delay_started = fixture / "contended-marker.started"
contended_env = dict(env, TERM_PANE_MARK_STATE=str(contended_pane))
args = [
    "python3",
    str(script),
    str(contended_dir),
    session + "-contended",
    current_owner,
    "codex",
    "root",
]
first = subprocess.Popen(
    [*args, "set"],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    env=dict(contended_env, TERM_PANE_MARK_DELAY_ONCE=str(delay_started)),
)
assert first.stdin is not None
first.stdin.write(json.dumps({"turn_id": "first"}))
first.stdin.close()
deadline = time.monotonic() + 4
while not delay_started.exists() and time.monotonic() < deadline:
    time.sleep(0.01)
assert delay_started.exists(), "delayed marker never acquired team lock"
second = subprocess.run(
    [*args, "clear"],
    input=json.dumps({"turn_id": "first"}),
    text=True,
    capture_output=True,
    env=contended_env,
    timeout=8,
    check=False,
)
assert second.returncode == 0, ("contended clear", second.returncode, second.stderr)
assert first.wait(timeout=8) == 0, "delayed set failed"
assert not contended_pane.exists(), "contended child completion was dropped"
