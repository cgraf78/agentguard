#!/usr/bin/env python3
"""Prove team state rejects a session as its own child and prunes legacy ones."""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

fixture = Path(sys.argv[1])
session = sys.argv[2]
state_dir = fixture / "self-state"
pane_state = fixture / "self-pane.state"
env = dict(os.environ, TERM_PANE_MARK_STATE=str(pane_state))
env["TERM_PANE_MARK_LOG"] = str(fixture / "self-pane.log")
env["PATH"] = str(fixture / "bin") + os.pathsep + env["PATH"]
script = Path(sys.argv[3])
owner = str(os.getpid())


def transition(actor: str, action: str, payload: dict[str, object]) -> None:
    """Call the real state transition with a fixed synthetic pane owner."""
    result = subprocess.run(
        ["python3", str(script), str(state_dir), session, owner, "muse", actor, action],
        input=json.dumps(payload),
        text=True,
        capture_output=True,
        env=env,
        check=False,
    )
    assert result.returncode == 0, (actor, action, result.returncode, result.stderr)


def children() -> dict[str, object] | None:
    """Read the recorded team children, if any state was published."""
    state_path = state_dir / "busy-team" / "state.json"
    if not state_path.exists():
        return None
    return json.loads(state_path.read_text()).get("children")


# A session cannot be its own child: the write is ignored, the pane untouched.
transition(
    "child",
    "set",
    {"session_id": session, "child_session_id": session, "turn_id": "t1"},
)
recorded = children()
assert recorded is None or recorded == {}, "self-child write was not ignored"
assert not pane_state.exists(), "self-child write marked the pane"

# Real children still record and mark.
transition(
    "child",
    "set",
    {"session_id": "child-a", "child_session_id": "child-a", "turn_id": "t1"},
)
assert children() == {"child-a": "t1"}, "real child write lost"
assert pane_state.exists(), "real child write did not mark the pane"

# A legacy self-entry is pruned by the next root set.
legacy_path = state_dir / "busy-team" / "state.json"
legacy = json.loads(legacy_path.read_text())
legacy["children"][session] = "t0"
legacy_path.write_text(json.dumps(legacy))
transition("root", "set", {"session_id": session, "turn_id": "t2"})
assert children() == {"child-a": "t1"}, "root set did not prune the self-child"
assert pane_state.exists(), "root set with a live child unmarked the pane"

# A legacy self-entry is pruned by an owning root clear as well.
legacy = json.loads(legacy_path.read_text())
legacy["children"][session] = "t0"
legacy_path.write_text(json.dumps(legacy))
transition("root", "clear", {"session_id": session, "turn_id": "t2"})
assert children() == {"child-a": "t1"}, "root clear did not prune the self-child"
assert pane_state.exists(), "root clear with a live child unmarked the pane"
