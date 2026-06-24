# Test Harness

`test/agentguard-test` is the repo-owned test runner used by CI. It loads
`test/helpers.sh`, discovers suites under `test/suites/`, and runs each suite in
an isolated fixture environment.

## Suite Scope

Prefer narrow suites that match a hook family or policy area:

- command parsing and safety classification
- protected Git operation handling
- edit, MCP, prompt, stop, session, and notification hooks
- host-specific payload compatibility

Tests should assert machine behavior: exit status, emitted JSON/text fragments
that are part of the contract, and filesystem side effects. Avoid asserting
incidental prose unless that prose is the warning a host agent surfaces to the
user.

Performance suites should enforce coarse latency budgets for common hook paths,
not microbenchmark implementation details. Keep thresholds generous enough for
loaded CI hosts while still catching gross regressions such as accidental sleeps,
network calls, process scans, or expensive command classification on cheap paths.
