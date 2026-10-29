# Test Harness

`test/agentguard-test` is the repo-owned test runner used by CI. It loads
`test/helpers.sh`, discovers suites under `test/suites/`, and runs each suite in
an isolated fixture environment.

The parallel runner requires Python 3.9 or newer with POSIX `waitid` and
`WNOWAIT` (Linux, macOS, and Termux). It creates each suite's session once in
the child, observes completion without reaping its leader, and reserves that
identity until descendant teardown is finished. This avoids Bash monitor
mode's concurrent parent/child `setpgid` calls and prevents cleanup from
signalling a reused process group. Unsupported supervision fails before any
suite starts. AgentGuard tests do not require Dot.
On Android, the runner supports ordinary unprivileged app execution. Process
privacy denials are excluded only when proc directory metadata proves another
UID; inaccessible same-UID or unknown-owner entries fail cleanup closed. Root
execution receives no privacy exception. Linux retains the process-group check
because descendants there may change UID through setuid executables.

## Suite Scope

Prefer narrow suites that match a hook family or policy area:

- command parsing and safety classification
- protected Git operation handling
- edit, MCP, prompt, stop, session, and notification hooks
- host-specific payload compatibility
- `install-test` covers the standalone checkout-backed command and manpage
  links, idempotent retargeting, custom destinations, complete source
  preflight, and refusal to overwrite user-owned paths.

Tests should assert machine behavior: exit status, emitted JSON/text fragments
that are part of the contract, and filesystem side effects. Avoid asserting
incidental prose unless that prose is the warning a host agent surfaces to the
user.

Performance suites should enforce coarse latency budgets for common hook paths,
not microbenchmark implementation details. Keep thresholds generous enough for
loaded CI hosts while still catching gross regressions such as accidental sleeps,
network calls, process scans, or expensive command classification on cheap paths.
