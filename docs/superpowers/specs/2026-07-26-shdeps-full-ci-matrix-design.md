# Shdeps Dependency Full CI Matrix

## Goal

Run every cgraf78 repository consumed by dotfiles through the shared full
shell-platform matrix on pushes and pull requests, then make that coverage a
consistent merge requirement.

## Repository Scope

The rollout covers the cgraf78 repositories declared by dotfiles shdeps
configuration:

- `agentguard`
- `checkrun`
- `cmdblocks`
- `ds`
- `git-tools`
- `hive-memory`
- `sley`
- `termnav`
- `tmux-tools`
- `grafhome-ca`

`cgraf78/actions` is not modified. Every currently pinned `shell-ci.yml`
revision already supports the `full` matrix alias.

## Workflow Changes

Add `matrix-set: full` to every `shell-ci.yml` caller in scope. Preserve each
caller's immutable actions pin, dependency profiles, setup mode, and test
command.

`checkrun` has two independent shell callers, `shell` and `shellcheck`; both
use the full matrix. The Rust, performance, cloud-sync, integration, and other
specialized jobs in `hive-memory` and `grafhome-ca` remain unchanged.

Existing Android package and Termux coverage in `hive-memory` and
`grafhome-ca` is preserved. No Android or Termux job is added to the other
repositories.

## Pull Requests and Verification

Use one isolated worktree, branch, and pull request per repository. Each PR
contains only its workflow configuration change, plus this coordination spec
in the first rollout repository. Validate the changed workflow with
`actionlint`, run the repository's normal local test command, and let the PR
exercise the real full matrix.

Land each PR only when its current head is green. A job that fails without a
runner, steps, or logs is infrastructure uncertainty and must be distinguished
from a repository test failure before retrying or landing.

## Required Checks

After a repository's workflow PR lands, configure strict required status
checks bound to the GitHub Actions app. Require the selector and all eight
platform results from every full shell caller:

- `select-platforms`
- `macOS`
- `CentOS Stream`
- `Arch`
- `Debian`
- `Ubuntu`
- `WSL`
- `Fedora`
- `Alpine`

For the ordinary `shell` caller, the contexts are
`shell / Platforms / <result>`. `checkrun` additionally requires the same
complete context family under `shellcheck / Platforms / <result>`.

Retain every existing non-shell required check, including Rust quality and
platform checks, performance and cloud-sync jobs, and Grafhome integration
jobs. Do not add or remove Android or Termux requirements. Repositories such
as `ds` that currently lack required checks receive the standardized strict
full-shell gate.

Read back branch protection after every update and verify strict mode, exact
context names, and the Actions app binding.

## Landing Order and Cleanup

Repositories are independent and may progress separately. For each one:

1. base the worktree on the latest `origin/main`;
2. make and locally validate the narrow workflow change;
3. open the repository-specific PR;
4. wait for the complete current-head matrix;
5. squash-merge when green;
6. synchronize local `main`;
7. update and verify branch protection; and
8. remove only the completed worktree and feature branch.

Existing unrelated worktrees and user changes are never modified.
