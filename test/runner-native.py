"""Check native suite ownership without reaching hooks or live application state."""

from __future__ import annotations

import importlib.util
import inspect
import json
import os
import select
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

CASE_TIMEOUT = 12
BATCH_TIMEOUT = 30


class NativeRunnerTest(unittest.TestCase):
    """Exercise the public runner with owned processes and persistence roots."""

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="agentguard-native-runner-")
        self.root = Path(self.temporary.name)
        self.runner = Path(__file__).resolve().parent / "run-suites"
        self.env = dict(os.environ, HOME=str(self.root), AGENTGUARD_TEST_JOBS="2")
        for name in ("BASH_ENV", "ENV", "PYTHONPATH"):
            self.env.pop(name, None)
        for name in ("CONFIG", "CACHE", "DATA", "STATE"):
            self.env[f"XDG_{name}_HOME"] = str(self.root / name)
        self.env["XDG_RUNTIME_DIR"] = str(self.root / "runtime")

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def suite(self, name: str, body: str) -> Path:
        """Create one executable fixture with a known absolute interpreter."""
        path = self.root / name
        path.write_text(f"#!{sys.executable}\n" + body)
        path.chmod(0o700)
        return path

    def run_suites(self, *suites: Path, **kwargs) -> subprocess.CompletedProcess[str]:
        """Keep each runner invocation bounded and capture both output channels."""
        return subprocess.run(
            [str(self.runner), *map(str, suites)],
            env=self.env,
            capture_output=True,
            text=True,
            timeout=CASE_TIMEOUT,
            **kwargs,
        )

    def test_worker_has_its_own_native_session(self) -> None:
        suite = self.suite(
            "identity",
            "import json,os\nprint(json.dumps([os.getpid(),os.getpgrp(),os.getsid(0)]))\n",
        )
        result = self.run_suites(suite)
        self.assertEqual(result.returncode, 0, result.stderr)
        pid, group, session = json.loads(result.stdout)
        self.assertEqual((group, session), (pid, pid))

    @unittest.skipUnless(sys.platform == "darwin", "stock macOS Python compatibility")
    def test_stock_system_python_runs_the_public_cli(self) -> None:
        stock = Path("/usr/bin/python3")
        if not stock.is_file():
            self.skipTest("system Python is unavailable")
        expected = subprocess.check_output(
            [str(stock), "-c", "import sys;print(sys.executable)"], text=True
        ).strip()
        marker = self.root / "interpreter"
        site = self.root / "site"
        site.mkdir()
        (site / "sitecustomize.py").write_text(
            "import sys\nfrom pathlib import Path\n"
            f"Path({str(marker)!r}).write_text(sys.executable)\n"
        )
        self.env.update(PATH="/usr/bin:/bin", PYTHONPATH=str(site))
        suite = self.root / "stock-suite"
        suite.write_text("#!/bin/sh\nprintf 'stock-ok\\n'\n")
        suite.chmod(0o700)
        result = self.run_suites(suite)
        self.assertEqual((result.returncode, result.stdout), (0, "stock-ok\n"), result.stderr)
        self.assertEqual(marker.read_text(), expected)

    def load_runner(self):
        """Load the private policy owner for deterministic scheduling injection."""
        spec = importlib.util.spec_from_file_location(
            "native_runner_under_test", self.runner.with_suffix(".py")
        )
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        return module

    def restricted_snapshot(
        self,
        *,
        android: bool,
        owner: int | None,
        groups: set[int],
        caller: int = 10000,
        known_group: int | None = None,
        signal_error: OSError | None = None,
    ):
        """Model Android denying both stat contents and getpgid for another app."""
        module = self.load_runner()
        proc = self.root / "proc"
        (proc / "self").mkdir(parents=True)
        (proc / "self" / "stat").touch()
        foreign = proc / "41"
        foreign.mkdir()
        owned = proc / "42"
        owned.mkdir()
        (owned / "stat").write_bytes(b"42 (suite) S 1 42 42 0")
        original_stat = Path.stat
        original_read = Path.read_bytes

        def path(value):
            value = Path(value)
            return proc / value.relative_to("/proc") if value.is_relative_to("/proc") else value

        def metadata(value, *args, **kwargs):
            if value == foreign:
                if owner is None:
                    raise PermissionError(13, "private process metadata")
                return SimpleNamespace(st_uid=owner)
            return original_stat(value, *args, **kwargs)

        def contents(value):
            if value == foreign / "stat":
                raise PermissionError(13, "private process stat")
            return original_read(value)

        with (
            patch.object(module, "Path", path),
            patch.object(Path, "stat", metadata),
            patch.object(Path, "read_bytes", contents),
            patch.dict(module.sys.__dict__),
            patch.object(module.sys, "platform", "android" if android else "linux"),
            patch.object(module.os, "geteuid", return_value=caller),
            patch.object(module.os, "kill", side_effect=signal_error),
            patch.object(
                module.os,
                "getpgid",
                return_value=known_group,
                side_effect=PermissionError(13, "private pgid") if known_group is None else None,
            ),
        ):
            if android:
                module.sys.getandroidapilevel = lambda: 31
            else:
                module.sys.__dict__.pop("getandroidapilevel", None)
            return module.live_members(groups)

    def test_android_foreign_app_privacy_does_not_block_owned_snapshot(self) -> None:
        self.assertEqual(
            self.restricted_snapshot(android=True, owner=10001, groups={42}), {42: [42]}
        )

    def test_android_unreadable_same_uid_stays_fail_closed(self) -> None:
        with self.assertRaises(PermissionError):
            self.restricted_snapshot(android=True, owner=10000, groups={42})

    def test_android_unknown_owner_stays_fail_closed(self) -> None:
        with self.assertRaises(PermissionError):
            self.restricted_snapshot(android=True, owner=None, groups={42})

    def test_linux_denied_foreign_uid_stays_fail_closed(self) -> None:
        with self.assertRaises(PermissionError):
            self.restricted_snapshot(android=False, owner=10001, groups={42})

    def test_android_root_denial_stays_fail_closed(self) -> None:
        with self.assertRaises(PermissionError):
            self.restricted_snapshot(android=True, owner=10001, groups={42}, caller=0)

    def test_linux_known_unowned_group_denial_is_excluded(self) -> None:
        self.assertEqual(
            self.restricted_snapshot(android=False, owner=10001, groups={42}, known_group=41),
            {42: [42]},
        )

    def test_known_owned_group_denial_stays_fail_closed(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "cannot inspect owned group member 41"):
            self.restricted_snapshot(android=True, owner=10001, groups={42}, known_group=42)

    def test_empty_owned_group_set_never_scans_foreign_processes(self) -> None:
        module = self.load_runner()
        with patch.object(module.Path, "iterdir", side_effect=AssertionError("global scan")):
            self.assertEqual(module.live_members(set()), {})

    def test_android_hidden_owner_with_denied_signal_is_foreign(self) -> None:
        self.assertEqual(
            self.restricted_snapshot(
                android=True,
                owner=None,
                groups={42},
                signal_error=PermissionError(1, "foreign signal authority"),
            ),
            {42: [42]},
        )

    def test_android_hidden_owner_that_vanishes_is_excluded(self) -> None:
        self.assertEqual(
            self.restricted_snapshot(
                android=True,
                owner=None,
                groups={42},
                signal_error=ProcessLookupError(3, "process vanished"),
            ),
            {42: [42]},
        )

    def test_android_hidden_owner_eacces_stays_fail_closed(self) -> None:
        with self.assertRaises(PermissionError):
            self.restricted_snapshot(
                android=True,
                owner=None,
                groups={42},
                signal_error=PermissionError(13, "security policy denied signal probe"),
            )

    def test_android_hidden_owner_probe_error_stays_fail_closed(self) -> None:
        with self.assertRaises(OSError):
            self.restricted_snapshot(
                android=True,
                owner=None,
                groups={42},
                signal_error=OSError(5, "probe unavailable"),
            )

    def test_android_known_same_uid_denial_overrides_signal_probe(self) -> None:
        with self.assertRaises(PermissionError):
            self.restricted_snapshot(
                android=True,
                owner=10000,
                groups={42},
                signal_error=PermissionError(1, "signal authority denied"),
            )

    @unittest.skipUnless(hasattr(sys, "getandroidapilevel"), "Android app privacy boundary")
    def test_android_kernel_signal_authority_matches_owned_scope(self) -> None:
        child = subprocess.Popen(
            [
                sys.executable,
                "-c",
                "import ctypes,sys; "
                "assert ctypes.CDLL(None).prctl(4,0,0,0,0)==0; "
                "print('ready',flush=True); sys.stdin.buffer.read()",
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            start_new_session=True,
        )
        report = {"caller_uid": os.geteuid(), "owned_pid": child.pid, "foreign_pid": 1}

        def probe(name, action):
            try:
                action()
                report[name] = None
            except OSError as error:
                report[name] = error.errno

        try:
            readable, _, _ = select.select([child.stdout], [], [], 5)
            self.assertTrue(readable, "nondumpable owned child did not become ready")
            self.assertEqual(child.stdout.readline(), b"ready\n")
            probe("foreign_stat_errno", lambda: Path("/proc/1/stat").read_bytes())
            probe("foreign_directory_errno", lambda: Path("/proc/1").stat())
            probe("foreign_group_errno", lambda: os.getpgid(1))
            probe("foreign_signal0_errno", lambda: os.kill(1, 0))
            probe("owned_signal0_errno", lambda: os.kill(child.pid, 0))
            print("android-privacy-probe " + json.dumps(report, sort_keys=True), flush=True)
            self.assertEqual(report["foreign_signal0_errno"], 1, report)
            self.assertIsNone(report["owned_signal0_errno"], report)
        finally:
            child.stdin.close()
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                # A failed readiness assertion must still settle our child.
                # Popen retains its identity until this final kill and reap.
                child.kill()
                child.wait(timeout=5)
            finally:
                child.stdout.close()

    def test_signals_at_replay_boundaries_are_preserved(self) -> None:
        module = self.load_runner()
        lines, start = inspect.getsourcelines(module.Runner.run)
        before = start + next(i for i, line in enumerate(lines) if line.strip() == "failed = 0")
        after = start + next(
            i for i, line in enumerate(lines) if line.strip().startswith("return failed")
        )
        for seam in ("before", "after", "exit"):
            runner = module.Runner(self.root)
            fired = False

            def trace(frame, event, _arg, selected_seam=seam, selected_runner=runner):
                nonlocal fired
                if event == "line" and frame.f_code is module.Runner.run.__code__:
                    if selected_seam == "before":
                        boundary = frame.f_lineno == before
                    elif selected_seam == "exit":
                        boundary = frame.f_lineno == after
                    else:
                        boundary = selected_runner.replaying
                    if boundary and not fired:
                        fired = True
                        sys.settrace(None)
                        selected_runner.interrupt(signal.SIGTERM, None)
                return trace

            previous = sys.gettrace()
            sys.settrace(trace)
            try:
                status = runner.run([], 1)
            finally:
                sys.settrace(previous)
            self.assertTrue(fired, seam)
            self.assertEqual(status, 143, seam)

    def test_late_member_is_killed_before_leader_is_reaped(self) -> None:
        module = self.load_runner()
        process = subprocess.Popen([sys.executable, "-c", "pass"], start_new_session=True)
        events = []
        try:
            deadline = time.monotonic() + 3
            while not module.wait_exited(process.pid):
                self.assertLess(time.monotonic(), deadline)
                time.sleep(0.01)
            worker = module.Worker("fixture", self.root / "log", process)
            observations = iter([{}, {}, {process.pid: [999999]}, {}, {}])

            def snapshot(_groups):
                value = next(observations, {})
                events.append("late" if value else "empty")
                return value

            real_wait = process.wait

            def reap(timeout):
                events.append("reap")
                return real_wait(timeout=timeout)

            with (
                patch.object(module, "live_members", snapshot),
                patch.object(module.Worker, "send", lambda _worker, sig: events.append(sig)),
                patch.object(process, "wait", reap),
            ):
                module.Runner(self.root).stop([worker])
            self.assertIn("late", events)
            self.assertIn(signal.SIGKILL, events[events.index("late") + 1 : events.index("reap")])
            self.assertEqual(events[-3:], [signal.SIGKILL, "empty", "reap"])
        finally:
            process.wait(timeout=3)

    def test_missing_waitid_fails_before_any_suite(self) -> None:
        marker = self.root / "launched"
        suite = self.suite("marker", f"from pathlib import Path\nPath({str(marker)!r}).touch()\n")
        site = self.root / "site"
        site.mkdir()
        (site / "sitecustomize.py").write_text(
            "import os,sys\nos.__dict__.pop('waitid',None)\nsys.platform='linux'\n"
        )
        self.env["PYTHONPATH"] = str(site)
        result = self.run_suites(suite)
        self.assertEqual(result.returncode, 125, result.stderr)
        self.assertFalse(marker.exists(), "unsupported supervision launched a suite")

    def test_old_python_fails_before_any_suite(self) -> None:
        marker = self.root / "launched"
        suite = self.suite("marker", f"from pathlib import Path\nPath({str(marker)!r}).touch()\n")
        site = self.root / "site"
        site.mkdir()
        (site / "sitecustomize.py").write_text("import sys\nsys.version_info=(3,8,0)\n")
        self.env["PYTHONPATH"] = str(site)
        result = self.run_suites(suite)
        self.assertEqual(result.returncode, 125, result.stderr)
        self.assertFalse(marker.exists(), "unsupported Python launched a suite")

    def run_batch(self, suite: Path, count: int, *, stall: float = BATCH_TIMEOUT):
        """Bound launch stalls separately from a progressing multi-suite batch."""
        read_fd, write_fd = os.pipe()
        env = dict(self.env, RUNNER_ACK_FD=str(write_fd))
        runner = None
        started = time.monotonic()
        completed = 0
        failure = None
        stdout = stderr = ""
        try:
            runner = subprocess.Popen(
                [str(self.runner), *([str(suite)] * count)],
                env=env,
                pass_fds=(write_fd,),
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            os.close(write_fd)
            write_fd = None
            # stop() settles completed workers serially. Keep a finite budget
            # per declared launch. The stall/drain budget allows two active
            # workers' serialized TERM(5), KILL(2), snapshot(2), and reap(2)
            # stages plus scheduling margin. This is not a performance test.
            # Only a target's ACK resets the stall clock.
            absolute = started + count * CASE_TIMEOUT
            progress = started + BATCH_TIMEOUT
            while completed < count:
                remaining = min(progress, absolute) - time.monotonic()
                ready, _, _ = select.select([read_fd], [], [], max(0, remaining))
                if remaining <= 0 or not ready:
                    raise TimeoutError(
                        f"batch stalled after {completed}/{count} launches; "
                        f"elapsed={time.monotonic() - started:.3f}s"
                    )
                chunk = os.read(read_fd, count - completed)
                if not chunk:
                    raise AssertionError(f"batch ACK stream closed at {completed}/{count}")
                self.assertEqual(chunk, b"+" * len(chunk), "invalid batch ACK")
                completed += len(chunk)
                progress = time.monotonic() + stall
            stdout, stderr = runner.communicate(
                timeout=min(BATCH_TIMEOUT, max(0, absolute - time.monotonic()))
            )
        except Exception as error:
            failure = error
        finally:
            os.close(read_fd)
            if write_fd is not None:
                os.close(write_fd)
            if runner is not None:
                # subprocess.run(timeout=...) would immediately kill the
                # supervisor, denying it the chance to settle owned groups.
                # These fixtures never fork; allow normal teardown first.
                if runner.poll() is None:
                    runner.terminate()
                try:
                    stdout, stderr = runner.communicate(timeout=BATCH_TIMEOUT)
                except subprocess.TimeoutExpired:
                    runner.kill()
                    stdout, stderr = runner.communicate(timeout=2)
        if failure is not None:
            raise AssertionError(
                f"batch failed after {completed}/{count} launches; "
                f"elapsed={time.monotonic() - started:.3f}s; "
                f"stdout={stdout!r}; stderr={stderr!r}; cause={failure}"
            ) from failure
        return subprocess.CompletedProcess(runner.args, runner.returncode, stdout, stderr)

    def test_batch_stall_reports_progress_and_settles_the_supervisor(self) -> None:
        pid_file = self.root / "stalled-pid"
        target = self.suite(
            "stalled",
            "import os,signal\nfrom pathlib import Path\n"
            f"Path({str(pid_file)!r}).write_text(str(os.getpid()))\n"
            "os.write(int(os.environ['RUNNER_ACK_FD']),b'+')\nsignal.pause()\n",
        )
        original = self.runner
        # Capture a supervisor-side diagnostic even when cancellation prevents
        # replay of the suites' captured logs. The wrapper preserves its PID.
        self.runner = self.suite(
            "diagnostic-runner",
            "import os,sys\n"
            "os.write(2,b'controlled supervisor diagnostic\\n')\n"
            f"os.execv({str(original)!r},[{str(original)!r},*sys.argv[1:]])\n",
        )
        self.env["AGENTGUARD_TEST_JOBS"] = "1"
        with self.assertRaises(AssertionError) as caught:
            self.run_batch(target, 2, stall=1)
        self.assertIn("after 1/2 launches", str(caught.exception))
        self.assertIn("controlled supervisor diagnostic", str(caught.exception))
        self.assertFalse(self.running(int(pid_file.read_text())), "stalled target survived cleanup")

    def test_silent_fast_failures_preserve_status_without_shell_noise(self) -> None:
        suite = self.suite(
            "silent",
            "import os\nos.write(int(os.environ['RUNNER_ACK_FD']),b'+')\nraise SystemExit(6)\n",
        )
        result = self.run_batch(suite, 40)
        self.assertEqual(result.returncode, 6)
        self.assertEqual((result.stdout, result.stderr), ("", ""))

    def test_inherited_environment_and_descriptor_reach_the_suite(self) -> None:
        read_fd, write_fd = os.pipe()
        self.env.update(RUNNER_FD=str(write_fd), RUNNER_VALUE="line one\n雪  ")
        suite = self.suite(
            "inherit",
            "import json,os\n"
            "os.write(int(os.environ['RUNNER_FD']), b'preserved')\n"
            "print(json.dumps(os.environ['RUNNER_VALUE']))\n",
        )
        try:
            result = self.run_suites(suite, pass_fds=(write_fd,))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout), self.env["RUNNER_VALUE"])
            os.close(write_fd)
            write_fd = -1
            self.assertEqual(os.read(read_fd, 100), b"preserved")
        finally:
            os.close(read_fd)
            if write_fd >= 0:
                os.close(write_fd)

    def test_missing_executable_preserves_declared_order_and_runs_other_suites(self) -> None:
        suite = self.suite("later", "print('later ran')\n")
        result = self.run_suites(self.root / "missing", suite)
        self.assertEqual(result.returncode, 127, result.stderr)
        self.assertIn("missing", result.stdout)
        self.assertTrue(result.stdout.rstrip().endswith("later ran"))

    def test_output_bytes_are_preserved(self) -> None:
        suite = self.suite(
            "bytes", "import os\nos.write(1,b'\\x00\\xff\\n')\nos.write(2,b'\\xfe')\n"
        )
        result = subprocess.run(
            [str(self.runner), str(suite)],
            env=self.env,
            capture_output=True,
            timeout=5,
            check=False,
        )
        self.assertEqual(
            (result.returncode, result.stdout, result.stderr), (0, b"\x00\xff\n\xfe", b"")
        )

    def test_standard_input_reaches_the_suite(self) -> None:
        suite = self.suite("stdin", "import sys\nsys.stdout.write(sys.stdin.read())\n")
        result = self.run_suites(suite, input="payload\n雪  ")
        self.assertEqual((result.returncode, result.stdout), (0, "payload\n雪  "))

    def test_worker_count_uses_the_existing_ascii_grammar(self) -> None:
        suite = self.suite("should-not-run", "raise SystemExit(19)\n")
        for value in ("0", "01", "-1", "٢", "1.0", "", " 2"):
            with self.subTest(value=value):
                self.env["AGENTGUARD_TEST_JOBS"] = value
                self.assertEqual(self.run_suites(suite).returncode, 2)

    def test_term_interrupts_backpressured_output_replay(self) -> None:
        suite = self.suite("large-output", "import os\nos.write(1,b'x'*(2*1024*1024))\n")
        runner = subprocess.Popen(
            [str(self.runner), str(suite)],
            env=self.env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        try:
            ready, _, _ = select.select([runner.stdout], [], [], 5)
            self.assertTrue(ready, "runner did not begin replay")
            self.assertEqual(runner.stdout.read(1), b"x")
            runner.terminate()
            self.assertEqual(runner.wait(timeout=2), 143)
        finally:
            if runner.poll() is None:
                runner.kill()
                runner.wait(timeout=2)
            runner.stdout.close()
            runner.stderr.close()

    def test_disappeared_proc_process_needs_no_ps_command(self) -> None:
        # Minimal Linux images expose procfs without installing procps. Once
        # a child vanishes there, its absence must not invoke an external ps.
        with (
            patch.object(Path, "is_file", return_value=True),
            patch.object(Path, "exists", return_value=False),
            patch.object(Path, "read_bytes", side_effect=FileNotFoundError),
            patch.object(subprocess, "run", side_effect=AssertionError("ps must not run")),
        ):
            self.assertFalse(self.running(123))

    @staticmethod
    def running(pid: int) -> bool:
        """Treat a killed orphan zombie as stopped on minimal container PID 1."""
        stat = Path(f"/proc/{pid}/stat")
        if Path("/proc/self/stat").is_file():
            try:
                return stat.read_bytes().rsplit(b") ", 1)[1].split()[0] != b"Z"
            except (FileNotFoundError, ProcessLookupError):
                return False
        result = subprocess.run(
            ["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True, check=False
        )
        return (
            result.returncode == 0
            and bool(result.stdout.strip())
            and not result.stdout.lstrip().startswith("Z")
        )

    def orphan(self, handler: str) -> tuple[Path, int, int, Path, Path]:
        """Publish a fully initialized orphan whose lifetime the test can release."""
        read_fd, write_fd = os.pipe()
        ready = self.root / "orphan.ready"
        records = self.root / "orphan.pid"
        caught = self.root / "orphan.term"
        child_code = (
            "import os,signal\nfrom pathlib import Path\n"
            f"fd={read_fd}\n"
            "def stop(signum,frame):\n"
            f"    Path({str(caught)!r}).touch()\n"
            "    os.read(fd,1)\n    raise SystemExit(0)\n"
            f"signal.signal(signal.SIGTERM,{handler})\n"
            f"Path({str(ready)!r}).touch()\n"
            "os.read(fd,1)\n"
        )
        suite = self.suite(
            "orphan",
            "import os,subprocess,sys,time\nfrom pathlib import Path\n"
            f"child=subprocess.Popen([sys.executable,'-c',{child_code!r}],pass_fds=({read_fd},))\n"
            f"Path({str(records)!r}).write_text(str(child.pid))\n"
            "deadline=time.monotonic()+3\n"
            f"while not Path({str(ready)!r}).exists():\n"
            "    assert time.monotonic()<deadline\n    time.sleep(0.01)\n",
        )
        return suite, read_fd, write_fd, records, caught

    def test_normal_completion_kills_a_term_ignoring_orphan_before_return(self) -> None:
        suite, read_fd, write_fd, records, _ = self.orphan("signal.SIG_IGN")
        try:
            result = self.run_suites(suite, pass_fds=(read_fd,))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(
                self.running(int(records.read_text())), "orphan survived runner completion"
            )
        finally:
            os.close(read_fd)
            os.close(write_fd)

    def test_normal_completion_allows_orphan_term_cleanup(self) -> None:
        suite, read_fd, write_fd, _, caught = self.orphan("stop")
        runner = subprocess.Popen(
            [str(self.runner), str(suite)],
            env=self.env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            pass_fds=(read_fd,),
        )
        try:
            deadline = time.monotonic() + 4
            while not caught.exists():
                self.assertIsNone(runner.poll(), "runner killed the orphan before its TERM handler")
                self.assertLess(time.monotonic(), deadline, "orphan did not receive TERM")
                time.sleep(0.01)
            self.assertIsNone(runner.poll(), "runner skipped the orphan's cleanup grace")
            os.write(write_fd, b"release")
            self.assertEqual(runner.wait(timeout=3), 0)
        finally:
            os.close(read_fd)
            os.close(write_fd)
            if runner.poll() is None:
                runner.terminate()
                try:
                    runner.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    runner.kill()
                    runner.wait(timeout=2)
            runner.stderr.close()

    def test_cancel_kills_a_term_ignoring_suite_and_straggler(self) -> None:
        # The test owns the only write end of this lifeline. Closing it also
        # releases both fixtures if a broken runner fails the cleanup assertion.
        read_fd, write_fd = os.pipe()
        records = self.root / "ready.json"
        self.env.update(RUNNER_LIFELINE=str(read_fd), RUNNER_RECORDS=str(records))
        suite = self.suite(
            "stubborn",
            """import json,os,signal,subprocess,sys
from pathlib import Path
signal.signal(signal.SIGTERM, signal.SIG_IGN)
fd=int(os.environ['RUNNER_LIFELINE'])
child=subprocess.Popen([sys.executable,'-c',
    'import os,signal; signal.signal(signal.SIGTERM,signal.SIG_IGN); '
    'os.read('+str(fd)+',1)'],pass_fds=(fd,))
Path(os.environ['RUNNER_RECORDS']).write_text(json.dumps([os.getpid(),child.pid]))
os.read(fd,1)
child.wait()
""",
        )
        runner = subprocess.Popen(
            [str(self.runner), str(suite)],
            env=self.env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            pass_fds=(read_fd,),
        )
        try:
            deadline = time.monotonic() + 5
            while not records.exists():
                self.assertIsNone(runner.poll(), "runner exited before fixture readiness")
                self.assertLess(time.monotonic(), deadline, "fixtures did not become ready")
                time.sleep(0.01)
            pids = json.loads(records.read_text())
            runner.send_signal(signal.SIGTERM)
            self.assertEqual(runner.wait(timeout=9), 143)
            deadline = time.monotonic() + 2
            while any(self.running(pid) for pid in pids) and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertFalse(
                any(self.running(pid) for pid in pids), "suite descendants survived cancellation"
            )
        finally:
            os.close(read_fd)
            os.close(write_fd)
            if runner.poll() is None:
                runner.terminate()
                try:
                    runner.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    runner.kill()
                    runner.wait(timeout=2)
            runner.stderr.close()


if __name__ == "__main__":
    unittest.main()
