# Hook Entrypoints

This directory contains the PATH-visible hook commands that agents call from
their configured lifecycle hooks. Keep these scripts small: they should parse
the hook payload, select the right shared library function, and exit with the
status the host agent expects.

Shared policy belongs in `lib/agentguard/`. When adding a hook command, also add
or extend a focused suite under `test/suites/` so the host-facing payload and
exit-code contract are protected.

Claude-specific wrappers are intentionally separate from generic hook scripts
where the host runtime needs a distinct command name or payload shape.
