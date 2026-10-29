#!/usr/bin/env python3
"""Exercise lifecycle publication races through isolated installed hooks."""

from __future__ import annotations

import fcntl
import json
import os
import shutil
import signal
import subprocess
import sys
import time
from collections.abc import Callable
from pathlib import Path

fixture = Path(sys.argv[1])
session = sys.argv[2]
state = Path(os.environ["XDG_RUNTIME_DIR"]) / "agentguard/hook-state" / session
notices = fixture / "notices"
owned: list[subprocess.Popen[bytes]] = []
env = dict(os.environ, AGENTGUARD_NAME="claude", AGENTGUARD_SESSION_ID=session)
env["PATH"] = str(fixture / "bin") + os.pathsep + env["PATH"]
env["ATTENTION_TEST_LOG"] = str(notices)


def wait_for(predicate: Callable[[], bool], description: str) -> None:
    """Wait on a concrete fixture boundary with a diagnostic deadline."""
    deadline = time.monotonic() + 8
    while not predicate():
        if time.monotonic() > deadline:
            raise AssertionError(f"timeout: {description}; processes={[p.poll() for p in owned]}")
        time.sleep(0.01)


def start(hook: str, turn: str, extra: dict[str, str] | None = None) -> subprocess.Popen[bytes]:
    """Launch and retain ownership of one real hook and all its descendants."""
    payload = dict(session_id=session, turn_id=turn)
    if hook == "prompt-submit":
        payload["prompt"] = "Work."
    child_env = dict(env, ATTENTION_TEST_TURN=turn, **(extra or {}))
    process = subprocess.Popen(
        [str(fixture / "bin" / ("agent-hook-" + hook))],
        stdin=subprocess.PIPE,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        env=child_env,
        start_new_session=True,
    )
    owned.append(process)
    process.stdin.write(json.dumps(payload).encode())
    process.stdin.close()
    return process


def finish(process: subprocess.Popen[bytes]) -> None:
    """Reap a hook, rejecting unexpected runtime failures."""
    assert process.wait(timeout=8) == 0


def run(hook: str, turn: str) -> None:
    finish(start(hook, turn))


try:
    notifier = fixture / "bin/term-notify-sound"
    notifier.write_text("""#!/usr/bin/env bash
printf '%s\\n' "$ATTENTION_TEST_TURN" >>"$ATTENTION_TEST_LOG"
if [ -n "${ATTENTION_TEST_GATE:-}" ]; then
  printf '%s\\n' "$PPID" >"$ATTENTION_TEST_GATE.owner"
  : >"$ATTENTION_TEST_GATE.started"
  until [ -e "$ATTENTION_TEST_GATE.release" ]; do sleep 0.01; done
  : >"$ATTENTION_TEST_GATE.finished"
fi
""")
    notifier.chmod(0o700)
    python = fixture / "bin/python3"
    python.write_text(
        '''#!/usr/bin/env bash
[ -z "${ATTENTION_TEST_WAIT:-}" ] || : >"$ATTENTION_TEST_WAIT"
exec "'''
        + sys.executable
        + """" "$@"
"""
    )
    python.chmod(0o700)

    run("prompt-submit", "A")
    gate = fixture / "gate"
    first = start("stop", "A", {"ATTENTION_TEST_GATE": str(gate)})
    wait_for(lambda: Path(str(gate) + ".started").exists(), "Stop A entered notifier")
    waiting = fixture / "waiting"
    next_prompt = start("prompt-submit", "B", {"ATTENTION_TEST_WAIT": str(waiting)})
    wait_for(waiting.exists, "Prompt B attempted attention transaction")
    assert next_prompt.poll() is None, "Prompt B passed a still-publishing Stop A"
    Path(str(gate) + ".release").touch()
    finish(first)
    finish(next_prompt)
    run("stop", "A")
    run("stop", "B")
    assert notices.read_text().splitlines() == ["A", "B"], "late A consumed B's bell"

    run("prompt-submit", "C")
    duplicate_stops = [start("stop", "C"), start("stop", "C")]
    for process in duplicate_stops:
        finish(process)
    assert notices.read_text().splitlines() == ["A", "B", "C"], "duplicate Stop rang twice"

    run("prompt-submit", "D")
    lock = state / "attention-lock"
    with lock.open("a") as held:
        fcntl.flock(held, fcntl.LOCK_EX)
        before = notices.read_bytes()
        run("stop", "D")
        assert notices.read_bytes() == before, "contended lock must fail silent"
    run("stop", "D")
    assert notices.read_text().splitlines()[-1] == "D"

    # A bounded prompt waiter must fence the old generation when it gives up.
    with lock.open("a") as held:
        fcntl.flock(held, fcntl.LOCK_EX)
        run("prompt-submit", "timed-out")
        assert list(state.glob("attention-disabled.*")), "failed reset left old owner admitted"
    before = notices.read_bytes()
    run("stop", "D")
    run("stop", "timed-out")
    assert notices.read_bytes() == before, "failed reset allowed stale publication"

    run("prompt-submit", "E")
    signal_gate = fixture / "signal-gate"
    interrupted = start("stop", "E", {"ATTENTION_TEST_GATE": str(signal_gate)})
    wait_for(lambda: Path(str(signal_gate) + ".started").exists(), "Stop E entered notifier")
    os.killpg(interrupted.pid, signal.SIGTERM)
    interrupted.wait(timeout=8)
    with lock.open("a") as released:
        fcntl.flock(released, fcntl.LOCK_EX | fcntl.LOCK_NB)
    run("prompt-submit", "F")
    run("stop", "F")
    assert notices.read_text().splitlines()[-1] == "F", "signal prevented next turn's bell"
    # Killing the lock shell cannot release admission while its actual tty
    # writer survives: the synchronous notifier retains the same kernel lock.
    run("prompt-submit", "I")
    kill_gate = fixture / "kill-gate"
    killed = start("stop", "I", {"ATTENTION_TEST_GATE": str(kill_gate)})
    wait_for(lambda: Path(str(kill_gate) + ".started").exists(), "Stop I entered notifier")
    owner = int(Path(str(kill_gate) + ".owner").read_text())
    os.kill(owner, signal.SIGKILL)
    with lock.open("a") as contender:
        try:
            fcntl.flock(contender, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            pass
        else:
            raise AssertionError("SIGKILL released lock before surviving writer finished")
    next_waiting = fixture / "next-waiting"
    after_kill = start("prompt-submit", "J", {"ATTENTION_TEST_WAIT": str(next_waiting)})
    wait_for(next_waiting.exists, "Prompt J attempted transaction after owner SIGKILL")
    assert after_kill.poll() is None
    Path(str(kill_gate) + ".release").touch()
    wait_for(lambda: Path(str(kill_gate) + ".finished").exists(), "orphan notifier finished")
    finish(killed)
    finish(after_kill)
    run("stop", "J")
    assert notices.read_text().splitlines()[-1] == "J", (
        "SIGKILL left permanent notification silence"
    )

    # A failed newer prompt must remain fenced even when an older reset was
    # already inside its transaction and finishes clearing prior failures.
    real_mv = shutil.which("mv")
    if real_mv is None:
        raise SystemExit("attention notification fixture requires mv on PATH")
    mv = fixture / "bin/mv"
    mv.write_text(
        '''#!/usr/bin/env bash
if [ -n "${ATTENTION_TEST_MV_GATE:-}" ]; then
  : >"$ATTENTION_TEST_MV_GATE.started"
  until [ -e "$ATTENTION_TEST_MV_GATE.release" ]; do sleep 0.01; done
fi
exec "'''
        + real_mv
        + """" "$@"
"""
    )
    mv.chmod(0o700)
    reset_gate = fixture / "reset-gate"
    old_reset = start("prompt-submit", "K", {"ATTENTION_TEST_MV_GATE": str(reset_gate)})
    wait_for(lambda: Path(str(reset_gate) + ".started").exists(), "older reset before publication")
    run("prompt-submit", "L")
    Path(str(reset_gate) + ".release").touch()
    finish(old_reset)
    before = notices.read_bytes()
    run("stop", "K")
    assert notices.read_bytes() == before, "older reset erased a newer failed prompt's fence"
    mv.unlink()
    run("prompt-submit", "M")
    run("stop", "M")
    assert notices.read_text().splitlines()[-1] == "M"

    # Failed replacement preserves the previous complete token and suppresses
    # notification instead of authorizing it for the previous generation.
    previous = (state / "attention-turn").read_bytes()
    mv = fixture / "bin/mv"
    mv.write_text("#!/usr/bin/env bash\nexit 1\n")
    mv.chmod(0o700)
    run("prompt-submit", "G")
    assert (state / "attention-turn").read_bytes() == previous
    assert not list(state.glob(".attention-turn.*")), "failed replacement leaked candidate"
    before = notices.read_bytes()
    run("stop", "F")
    run("stop", "G")
    assert notices.read_bytes() == before, "replacement failure admitted a stale turn"
    mv.unlink()
    run("prompt-submit", "H")
    run("stop", "H")
    assert notices.read_text().splitlines()[-1] == "H"
    assert (state / "attention-turn").stat().st_mode & 0o777 == 0o600

    # An independently installed older marker has no token-aware clear. If a
    # newer prompt fails rearm while the notifier is in flight, the final
    # compatibility retry must revalidate the fence before clearing its work.
    busy = fixture / "old-provider.busy"
    env["ATTENTION_TEST_BUSY"] = str(busy)
    marker = fixture / "bin/term-pane-mark"
    marker.write_text("""#!/usr/bin/env bash
case "$*" in *'--token '*) exit 64 ;; esac
case "$1" in
  set) : >"$ATTENTION_TEST_BUSY" ;;
  clear) rm -f "$ATTENTION_TEST_BUSY" ;;
esac
""")
    marker.chmod(0o700)
    run("prompt-submit", "old-A")
    old_gate = fixture / "old-provider-gate"
    old_stop = start("stop", "old-A", {"ATTENTION_TEST_GATE": str(old_gate)})
    wait_for(lambda: Path(str(old_gate) + ".started").exists(), "old provider before clear")
    run("prompt-submit", "old-B")
    assert busy.exists(), "newer prompt did not mark its work"
    Path(str(old_gate) + ".release").touch()
    finish(old_stop)
    assert busy.exists(), "delayed old-provider clear discarded newer failed-rearm work"
    run("prompt-submit", "old-C")
    run("stop", "old-C")
    assert not busy.exists(), "current old-provider completion lost compatibility clear"

finally:
    for gate_file in fixture.glob("*.started"):
        gate_file.with_suffix(".release").touch()
    for process in owned:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=8)
