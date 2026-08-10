# AgentGuard examples

These examples cover the two consumer-owned parts of an AgentGuard deployment:
adding local policy through a thin hook extension and reconciling a complete
provider generation into an existing native settings document. All names and
commands are synthetic.

## Hook policy extension

[`hooks/agent-hook-pre-bash-work`](hooks/agent-hook-pre-bash-work) blocks the
synthetic command `example-deploy --production` unless the caller supplies a
change identifier. It demonstrates the intended extension boundary:

- the base hook parses each runtime's JSON payload;
- the extension reads `AGENTGUARD_CMD_TRIMMED`;
- `_hook_block` contributes to AgentGuard's single native response; and
- policy stays outside the reusable base hook.

Install an environment extension beside the PATH-visible base hook, retaining
the `-work` suffix that AgentGuard discovers:

```sh
install -m 0644 agent-hook-pre-bash-work \
  "$HOME/.local/bin/agent-hook-pre-bash-work"
```

Replace the example command and variable with your own policy. Do not add that
policy to AgentGuard's runtime fragments: the fragments must remain reusable
and policy-free. Agent-specific extensions use the corresponding suffix such
as `-codex` or `-claude`; AgentGuard loads the agent extension first and the
environment extension second.

## Provider reconciliation

[`reconcile/live.json`](reconcile/live.json) contains user hooks, a different
agent's hook, mutable runtime state, and an obsolete AgentGuard generation.
[`reconcile/provider.json`](reconcile/provider.json) is the new complete
generation. [`reconcile/expected.json`](reconcile/expected.json) shows the
result: only commands owned by `AGENTGUARD_NAME=example` are replaced.

Run the provider-owned filter directly:

```sh
filter=$(shdeps dep-file cgraf78/agentguard \
  share/agentguard/integrations/_shared/reconcile-hooks.jq)
jq -n --arg agent example \
  --slurpfile d examples/reconcile/live.json \
  --slurpfile s examples/reconcile/provider.json \
  -f "$filter"
```

A real consumer should write that output to a private temporary file in the
destination directory, validate the runtime's native format, and atomically
rename it over the destination only after every step succeeds. A missing or
invalid provider asset is an update failure, not a request to erase the last
known-good hooks.

The fixtures are tested against the actual filter, including a second pass
that proves reconciliation is idempotent. This protects the example from
drifting as command envelopes and retirement support evolve.
