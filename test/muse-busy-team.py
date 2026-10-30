#!/usr/bin/env python3
"""Exercise Muse root and child hooks under one stable foreground owner."""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

fixture = Path(sys.argv[1])
session = sys.argv[2]
state = fixture / "muse-team.state"
log = fixture / "muse-team.log"
env = dict(os.environ, AGENTGUARD_NAME="muse", TERM_PANE_MARK_STATE=str(state))
env["TERM_PANE_MARK_LOG"] = str(log)
env["PATH"] = str(fixture / "bin") + os.pathsep + env["PATH"]


def hook(name: str, sid: str, payload: dict[str, object]) -> None:
    """Run a real hook with the same parent PID for every Muse event."""
    result = subprocess.run(
        [str(fixture / "bin" / ("agent-hook-" + name))],
        input=json.dumps(payload),
        text=True,
        capture_output=True,
        env=dict(env, AGENTGUARD_SESSION_ID=sid),
        check=False,
    )
    assert result.returncode == 0, (name, result.returncode, result.stderr)


def child(event: str, child_id: str) -> dict[str, object]:
    """Build a Muse child payload without a parent ID, as the host does."""
    payload: dict[str, object] = {
        "session_id": child_id,
        "turn_id": child_id,
        "hook_event_name": event,
        "transcript_path": None,
    }
    if event in ("SubagentStart", "SubagentStop"):
        payload.update(child_session_id=child_id, subagent_id=child_id)
    elif event == "PreToolUse":
        payload["tool_name"] = "read_file"
    return payload


hook(
    "prompt-submit",
    session,
    {"session_id": session, "turn_id": "root-a", "prompt": "Work."},
)
alpha = "01a1c001-0000-7000-8000-000000000001"
beta = "01a1c001-0000-7000-8000-000000000002"
for child_id in (alpha, beta):
    hook("telemetry", child_id, child("SubagentStart", child_id))
hook("stop", session, {"session_id": session, "turn_id": "root-a"})
assert state.exists(), "Muse root Stop cleared two running children"
hook("telemetry", alpha, child("SubagentStop", alpha))
assert state.exists(), "first Muse child Stop cleared the second child"
hook("telemetry", beta, child("PreToolUse", beta))
assert state.exists(), "Muse child tool lost the team mark"
hook("telemetry", beta, child("SubagentStop", beta))
assert not state.exists(), "last Muse child Stop left a stuck mark"
followup = child("PreToolUse", beta)
followup["turn_id"] = "beta-followup"
hook("telemetry", beta, followup)
assert state.exists(), "Muse child follow-up tool did not rearm without SubagentStart"
followup_stop = child("SubagentStop", beta)
followup_stop["turn_id"] = "beta-followup"
hook("telemetry", beta, followup_stop)
assert not state.exists(), "Muse child follow-up Stop left a stuck mark"

# Internal reminder agents are not user-directed team work. Their tool hooks
# must also stay unable to set an unpaired root mark.
reminder = "01a1c001-0000-7000-8000-000000000003"
internal = child("SubagentStart", reminder)
internal["subagent_id"] = "skill-reminder"
hook("telemetry", reminder, internal)
hook("telemetry", reminder, child("PreToolUse", reminder))
assert not state.exists(), "internal Muse reminder marked an idle pane"
