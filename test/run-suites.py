"""Run suites in native sessions while retaining every cleanup identity."""

from __future__ import annotations

import sys

# Keep the runtime gate even when lint itself targets a newer interpreter.
if sys.version_info < (3, 9):  # noqa: UP036
    print("run-suites: Python 3.9 or newer is required", file=sys.stderr)
    raise SystemExit(125)

import errno
import os
import re
import signal
import subprocess
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path

HANDLED_SIGNALS = (signal.SIGHUP, signal.SIGINT, signal.SIGQUIT, signal.SIGTERM)
_libc_waitid = None


def wait_exited(pid: int) -> bool:
    """Observe a child without reaping, including stock macOS Python 3.9."""
    required = ("waitid", "P_PID", "WEXITED", "WNOHANG", "WNOWAIT")
    if all(hasattr(os, name) for name in required):
        try:
            info = os.waitid(os.P_PID, pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
        except InterruptedError:
            return False
        observed = info.si_pid if info is not None else 0
    elif sys.platform == "darwin":
        # Stock CPython omits os.waitid although Darwin libc implements it.
        # Apple sys/signal.h defines a 128-byte siginfo_t whose si_pid is at
        # byte 12 (three int32 fields precede pid_t). The wait.h ABI values
        # are P_PID=1, WEXITED=4, WNOHANG=1, WNOWAIT=32. Do not guess this
        # layout on other platforms or fall back to a reaping waitpid.
        global _libc_waitid
        import ctypes

        if _libc_waitid is None:
            try:
                _libc_waitid = ctypes.CDLL(None, use_errno=True).waitid
            except AttributeError as error:
                raise RuntimeError("Darwin libc waitid is unavailable") from error
            _libc_waitid.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p, ctypes.c_int]
            _libc_waitid.restype = ctypes.c_int
        info = (ctypes.c_uint64 * 16)()
        if _libc_waitid(1, pid, info, 4 | 1 | 32) != 0:
            error = ctypes.get_errno()
            if error == errno.EINTR:
                return False
            raise OSError(error, os.strerror(error))
        observed = ctypes.c_int32.from_buffer(info, 12).value
    else:
        raise RuntimeError("native waitid/WNOWAIT is required")
    if observed not in (0, pid):
        raise RuntimeError("waitid returned a different child")
    return observed == pid


def android_app_uid(uid: int) -> bool:
    """Match Android UserHandle.isApp, excluding SDK sandbox and isolated UIDs."""
    # Android assigns each user a 100000-wide range. Only app IDs 10000
    # through 19999 carry the ordinary-app scope used by the privacy proof.
    return uid > 0 and 10000 <= uid % 100000 <= 19999


def live_members(groups: set[int]) -> dict[int, list[int]]:
    """Snapshot runnable members while the owned leaders reserve group IDs."""
    members: dict[int, list[int]] = {}
    if not groups:
        return members
    if Path("/proc/self/stat").is_file():
        for entry in Path("/proc").iterdir():
            if not entry.name.isascii() or not entry.name.isdecimal():
                continue
            try:
                fields = (entry / "stat").read_bytes().rsplit(b") ", 1)[1].split()
                state, group = fields[0], int(fields[2])
            except (FileNotFoundError, ProcessLookupError):
                continue
            except PermissionError:
                # Restricted procfs may hide unrelated accounts. We still need
                # complete evidence for every member of a group we own.
                try:
                    group = os.getpgid(int(entry.name))
                except ProcessLookupError:
                    continue
                except PermissionError as error:
                    # Android app privacy also denies getpgid across app UIDs.
                    # Ordinary app descendants cannot switch UID. Require
                    # directory ownership or kernel signal authority before
                    # treating a denial as foreign; same-UID or signalable
                    # unknown processes remain unproved. Linux
                    # permits setuid descendants, so never apply this there.
                    owner = None
                    if hasattr(sys, "getandroidapilevel") and android_app_uid(os.geteuid()):
                        try:
                            owner = entry.stat().st_uid
                        except (FileNotFoundError, ProcessLookupError):
                            continue
                        except PermissionError:
                            pass
                        if owner is not None and owner != os.geteuid():
                            continue
                        if owner is None:
                            # Android can hide even directory metadata (pid 1
                            # on stock Termux). Signal 0 delivers no signal:
                            # the kernel checks real/saved UID authority, and
                            # Android allows same-domain signull even for a
                            # nondumpable child. Ordinary app descendants keep
                            # that UID/domain, so EPERM excludes them; a
                            # signalable unknown process remains unproved.
                            try:
                                os.kill(int(entry.name), 0)
                            except ProcessLookupError:
                                continue
                            except PermissionError as denied:
                                if denied.errno == errno.EPERM:
                                    continue
                                raise
                    raise PermissionError(
                        error.errno,
                        f"process snapshot pid={entry.name} owner_uid={owner} "
                        f"caller_uid={os.geteuid()}: stat and getpgid denied",
                        str(entry / "stat"),
                    ) from error
                if group in groups:
                    raise RuntimeError(f"cannot inspect owned group member {entry.name}") from None
                continue
            if group in groups and state not in (b"Z", b"X"):
                members.setdefault(group, []).append(int(entry.name))
    else:
        # macOS has no procfs. These explicit machine fields avoid process
        # names, command quoting, and a dependency on GNU/BusyBox ps options.
        result = subprocess.run(
            ["/bin/ps", "-axo", "pid=,pgid=,stat="],
            capture_output=True,
            text=True,
            check=True,
            timeout=2,
        )
        for row in result.stdout.splitlines():
            pid, group, state = row.split()
            if int(group) in groups and not state.startswith("Z"):
                members.setdefault(int(group), []).append(int(pid))
    return members


class ReplayInterrupted(Exception):
    """Interrupt output writes only after all owned workers are settled."""


@dataclass
class Worker:
    """Own a child and its reserved group ID until teardown has finished."""

    suite: str
    log: Path
    process: subprocess.Popen[bytes] | None = None
    status: int | None = None
    observed: bool = False

    def exited(self) -> bool:
        """Observe completion without freeing a PID that cleanup still needs."""
        if self.process is None or self.observed:
            return True
        self.observed = wait_exited(self.process.pid)
        return self.observed

    def send(self, signum: int) -> None:
        """Signal only an unreaped owned group, including orphan descendants."""
        if self.process is None or self.status is not None:
            return
        try:
            os.killpg(self.process.pid, signum)
        except ProcessLookupError:
            pass
        except PermissionError:
            # Darwin rejects a zombie-only group. An exited leader alone is
            # insufficient proof: differently owned descendants could remain.
            if sys.platform != "darwin" or live_members({self.process.pid}):
                raise


class Runner:
    """Own launch registration, cancellation, output ordering, and teardown."""

    def __init__(self, root: Path) -> None:
        self.root = root
        self.workers: list[Worker] = []
        self.interrupted: int | None = None
        self.replaying = False

    def interrupt(self, signum: int, _frame: object) -> None:
        """Defer cleanup until a partially launched worker is registered."""
        if self.interrupted is None:
            self.interrupted = signum
        if self.replaying:
            # A second signal must not interrupt unwinding or its cleanup.
            self.replaying = False
            raise ReplayInterrupted

    def launch(self, suite: str) -> Worker:
        """Use one child-side setsid; Bash monitor mode races on Darwin 27."""
        worker = Worker(suite, self.root / f"{len(self.workers)}.log")
        self.workers.append(worker)
        old_mask = signal.pthread_sigmask(signal.SIG_BLOCK, HANDLED_SIGNALS)

        def restore_mask() -> None:
            signal.pthread_sigmask(signal.SIG_SETMASK, old_mask)

        try:
            # A handler may have run between run()'s check and this mask. Do
            # not admit new work after cancellation has already been recorded.
            if self.interrupted is not None:
                worker.status = 128 + self.interrupted
                return worker
            with worker.log.open("wb") as output:
                try:
                    worker.process = subprocess.Popen(
                        [suite],
                        stdout=output,
                        stderr=subprocess.STDOUT,
                        start_new_session=True,
                        preexec_fn=restore_mask,
                        # Match shell inheritance. Python-created private files
                        # are non-inheritable; caller leases must keep working.
                        close_fds=False,
                    )
                except OSError as error:
                    worker.status = 127 if error.errno == 2 else 126
                    output.write(f"run-suites: {suite}: {error}\n".encode())
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, old_mask)
        return worker

    def stop(self, workers: list[Worker]) -> None:
        """Finish group signals before reaping any leader can release its PID."""
        owned = [w for w in workers if w.process is not None and w.status is None]
        if not owned:
            return
        errors: list[str] = []
        # Signal all groups first: handlers in different suites may coordinate,
        # so waiting for one before signalling its peer would deadlock.
        for worker in owned:
            try:
                worker.send(signal.SIGTERM)
            except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
                errors.append(str(error))
        groups = {worker.process.pid for worker in owned}
        try:
            deadline = time.monotonic() + 5
            while live_members(groups):
                if time.monotonic() >= deadline:
                    break
                time.sleep(0.02)
        except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
            # Loss of observation is a failure, but must not prevent sending
            # the final signal to identities we still own and have not reaped.
            errors.append(str(error))
        # A snapshot can miss a late fork when its parent exits between PID
        # enumeration and stat inspection. Re-signal while the leaders reserve
        # every identity, and require consecutive empty observations.
        try:
            deadline = time.monotonic() + 2
            empty = 0
            while True:
                for worker in owned:
                    try:
                        worker.send(signal.SIGKILL)
                    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
                        errors.append(str(error))
                remaining = live_members(groups)
                empty = empty + 1 if not remaining else 0
                if empty >= 2:
                    break
                if time.monotonic() >= deadline:
                    errors.append(f"suite group cleanup did not quiesce: {remaining}")
                    break
                time.sleep(0.02)
        except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
            errors.append(str(error))
        if errors:
            # Do not release identities on incomplete proof. Final cleanup may
            # retry, but it never signals a leader that has already been reaped.
            raise RuntimeError("; ".join(errors))
        for worker in owned:
            try:
                code = worker.process.wait(timeout=2)
                worker.status = 128 - code if code < 0 else code
                if sys.stderr.isatty():
                    print(
                        f"run-suites: completed {Path(worker.suite).name} (status {worker.status})",
                        file=sys.stderr,
                    )
            except subprocess.TimeoutExpired:
                errors.append(f"could not reap suite {worker.suite}")
        if errors:
            raise RuntimeError("; ".join(errors))

    def run(self, suites: list[str], jobs: int) -> int:
        """Keep concurrency and report the first failure in declared order."""
        active: list[Worker] = []
        for suite in suites:
            while len(active) >= jobs and self.interrupted is None:
                for worker in active[:]:
                    if worker.exited():
                        self.stop([worker])
                        active.remove(worker)
                if len(active) >= jobs:
                    time.sleep(0.02)
            if self.interrupted is not None:
                break
            worker = self.launch(suite)
            if worker.process is not None:
                active.append(worker)
        while active and self.interrupted is None:
            for worker in active[:]:
                if worker.exited():
                    self.stop([worker])
                    active.remove(worker)
            if active:
                time.sleep(0.02)
        if self.interrupted is not None:
            self.stop(active)
            return 128 + self.interrupted
        failed = 0
        try:
            self.replaying = True
            if self.interrupted is not None:
                return 128 + self.interrupted
            for worker in self.workers:
                with worker.log.open("rb") as output:
                    while chunk := output.read(65536):
                        pending = memoryview(chunk)
                        while pending:
                            pending = pending[os.write(1, pending) :]
                if failed == 0 and worker.status:
                    failed = worker.status
            # Clear the exceptional phase while still inside its handler.
            self.replaying = False
        except ReplayInterrupted:
            return 128 + self.interrupted
        finally:
            self.replaying = False
        return failed if self.interrupted is None else 128 + self.interrupted


def main() -> int:
    """Reject unsupported supervision before allowing any user suite to run."""
    value = os.environ.get("AGENTGUARD_TEST_JOBS", "4")
    if re.fullmatch(r"[1-9][0-9]*", value) is None:
        print("run-suites: AGENTGUARD_TEST_JOBS must be a positive integer", file=sys.stderr)
        return 2
    if len(sys.argv) == 1:
        return 0
    if not hasattr(signal, "pthread_sigmask"):
        print("run-suites: native signal masks are required", file=sys.stderr)
        return 125
    # This process owns its children: inherited SIGCHLD auto-reaping would
    # invalidate the stable handles that cleanup needs.
    signal.signal(signal.SIGCHLD, signal.SIG_DFL)
    try:
        wait_exited(os.getpid())
    except ChildProcessError:
        pass
    except OSError as error:
        print(f"run-suites: native wait observation is unavailable: {error}", file=sys.stderr)
        return 125
    # With no workers there is no owned group to inspect. Validate only our
    # own procfs access; a global scan needlessly crosses Android app privacy.
    if Path("/proc/self/stat").is_file():
        Path("/proc/self/stat").read_bytes()
    else:
        live_members({os.getpgrp()})
    with tempfile.TemporaryDirectory(prefix="agentguard-run.") as temporary:
        runner = Runner(Path(temporary))
        for signum in HANDLED_SIGNALS:
            signal.signal(signum, runner.interrupt)
        try:
            return runner.run(sys.argv[1:], int(value))
        finally:
            runner.stop(runner.workers)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BrokenPipeError:
        raise SystemExit(128 + signal.SIGPIPE) from None
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
        print(f"run-suites: {error}", file=sys.stderr)
        raise SystemExit(125) from error
