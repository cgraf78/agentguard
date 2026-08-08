# Gemini CLI Integration

`hooks.json` is AgentGuard's complete hook-only Gemini CLI settings fragment.
Gemini uses its own lifecycle names and tool matcher vocabulary; those native
differences are preserved here instead of being hidden behind a shared config
generator or translated independently by every consumer.

Consumers should apply the file through `../_shared/reconcile-hooks.jq` as one
provider-owned generation, then apply local Gemini settings separately. That
refresh can retire an old event without replacing unrelated user hooks. The
fragment contains no permissions, model selection, UI preferences, or machine
policy. A missing fragment or reconciler should leave the complete existing
configuration intact and be reported as a failed refresh.

`test/suites/integration-assets-test` owns the exact event, matcher, timeout,
identity, and executable contract. Consumer tests should prove only resolution
and layering.
