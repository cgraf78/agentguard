# Shdeps Dependency Full CI Matrix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run every cgraf78 repository consumed by dotfiles through the shared full shell-platform matrix and enforce that coverage with consistent strict required checks.

**Architecture:** Each repository keeps its existing immutable shared-actions pin, setup, profiles, tests, and specialized jobs. A repository-specific PR adds `matrix-set: full` to every `shell-ci.yml` caller; after the PR is green and squash-merged, branch protection is replaced with the exact full shell context families plus all existing non-shell requirements, bound to the GitHub Actions app.

**Tech Stack:** GitHub Actions reusable workflows, YAML, `actionlint`, GitHub CLI, GitHub branch-protection REST API, Git worktrees

## Global Constraints

- Modify `agentguard`, `checkrun`, `cmdblocks`, `ds`, `git-tools`, `hive-memory`, `sley`, `termnav`, `tmux-tools`, and `grafhome-ca`.
- Do not modify `cgraf78/actions` or change any existing reusable-workflow pin.
- Add `matrix-set: full` to every `shell-ci.yml` caller.
- Preserve all existing setup modes, dependency profiles, test commands, specialized jobs, and non-shell required checks.
- Preserve existing Android package and Termux coverage in `hive-memory` and `grafhome-ca`.
- Do not add Android or Termux coverage elsewhere.
- Use one isolated worktree, branch, commit, and pull request per repository.
- Base every branch on the latest `origin/main`.
- Land only after the complete current-head CI result is green.
- Configure strict required checks bound to GitHub Actions after each workflow PR merges.
- Require the selector and all eight platforms for every full shell job family.
- Do not modify unrelated worktrees or user changes.

---

### Task 1: Complete `agentguard`

**Files:**

- Modify: `.github/workflows/test.yml`
- Create: `docs/superpowers/specs/2026-07-26-shdeps-full-ci-matrix-design.md` (already committed)
- Create: `docs/superpowers/plans/2026-07-26-shdeps-full-ci-matrix.md`

**Interfaces:**

- Consumes: `cgraf78/actions/.github/workflows/shell-ci.yml@7d88c3afa6e51a83e9cfefb0c12f503155e17952`

- Produces: the `shell / Platforms / ...` full-matrix context family

- [ ] **Step 1: Add the full matrix input**

Add this line under `jobs.shell.with` without changing neighboring inputs:

```yaml
      matrix-set: full
```

- [ ] **Step 2: Validate locally**

Run:

```bash
actionlint .github/workflows/test.yml
test/agentguard-test
git diff --check
```

Expected: every command exits zero and `agentguard-test` ends with
`agentguard-test: ok`.

- [ ] **Step 3: Commit and open the PR**

Commit the workflow, approved spec, and implementation plan with the standard
`Summary` and `Testing` sections. Push the explicit branch ref and open a PR
whose body explains the full matrix and unchanged shared-actions pin.

- [ ] **Step 4: Land and protect**

Wait for the selector plus macOS, CentOS Stream, Arch, Debian, Ubuntu, WSL,
Fedora, and Alpine to pass on the current head. Squash-merge, synchronize
`main`, and configure strict Actions-bound requirements for those nine
`shell / Platforms / ...` contexts.

---

### Task 2: Update `checkrun`

**Files:**

- Modify: `.github/workflows/test.yml`

**Interfaces:**

- Consumes: `cgraf78/actions/.github/workflows/shell-ci.yml@485940fa141828a3f13430b5219a3d5c33c4f367`

- Produces: complete `shell / Platforms / ...` and
  `shellcheck / Platforms / ...` context families

- [ ] **Step 1: Add both full matrix inputs**

Add `matrix-set: full` under both `jobs.shell.with` and
`jobs.shellcheck.with`. Preserve `setup: checkrun`, both test commands, and
the explanatory comments.

- [ ] **Step 2: Validate locally**

Run:

```bash
actionlint .github/workflows/test.yml
CHECKRUN_SKIP_SHELLCHECK_SUITES=1 test/checkrun-test
test/suites/shellcheck-inventory-test
test/suites/shellcheck-test
git diff --check
```

Expected: all commands exit zero.

- [ ] **Step 3: Commit, push, and open the PR**

Commit only `.github/workflows/test.yml`, push the explicit branch ref, and
open the repository-specific PR.

- [ ] **Step 4: Land and protect**

Require both selectors and all eight platforms under both `shell` and
`shellcheck` after the complete current-head run is green. Set strict mode,
bind all eighteen contexts to GitHub Actions, squash-merge, synchronize, and
clean the completed worktree.

---

### Task 3: Update `cmdblocks`

**Files:**

- Modify: `.github/workflows/test.yml`

**Interfaces:**

- Consumes: `shell-ci.yml@7d88c3afa6e51a83e9cfefb0c12f503155e17952`

- Produces: the full `shell / Platforms / ...` context family

- [ ] **Step 1: Add `matrix-set: full`**

Insert the input under `jobs.shell.with`; retain
`profiles: base,shellcheck` and `test-command: test/cmdblocks-test`.

- [ ] **Step 2: Validate**

Run:

```bash
actionlint .github/workflows/test.yml
test/cmdblocks-test
git diff --check
```

Expected: all commands exit zero.

- [ ] **Step 3: Ship**

Commit the workflow, push an explicit feature branch, open the PR, wait for
all nine shell contexts, squash-merge when green, and synchronize `main`.

- [ ] **Step 4: Standardize protection**

Replace the existing shell requirements with the exact full nine-context
family, set strict mode, bind to GitHub Actions, verify the readback, and
clean the completed worktree.

---

### Task 4: Update `ds`

**Files:**

- Modify: `.github/workflows/ci.yml`

**Interfaces:**

- Consumes: `shell-ci.yml@ac5330ce8cc9b5a060a0e21d6ef1a5457c183fb6`

- Produces: the full `shell / Platforms / ...` context family

- [ ] **Step 1: Add `matrix-set: full`**

Insert the input under `jobs.shell.with`; preserve the OpenSSH/netcat/lsof,
procps, and ShellCheck profiles and `bash tests/ds-ci`.

- [ ] **Step 2: Validate**

Run:

```bash
actionlint .github/workflows/ci.yml
bash tests/ds-ci
git diff --check
```

Expected: all commands exit zero.

- [ ] **Step 3: Ship**

Commit only the workflow, push explicitly, open the PR, and squash-merge only
after all nine shell contexts pass.

- [ ] **Step 4: Create the standardized gate**

`ds` has no current required checks. Create strict Actions-bound protection
requiring the full nine-context shell family, verify it through the API,
synchronize `main`, and clean the worktree.

---

### Task 5: Update `git-tools`

**Files:**

- Modify: `.github/workflows/test.yml`

**Interfaces:**

- Consumes: `shell-ci.yml@7d88c3afa6e51a83e9cfefb0c12f503155e17952`

- Produces: the full `shell / Platforms / ...` context family

- [ ] **Step 1: Add the full matrix**

Add `matrix-set: full` under `jobs.shell.with` and retain the base/ShellCheck
profiles and `test/run`.

- [ ] **Step 2: Validate and ship**

Run:

```bash
actionlint .github/workflows/test.yml
test/run
git diff --check
```

Commit only the workflow, push explicitly, and open the PR.

- [ ] **Step 3: Land and protect**

After all nine shell contexts pass, squash-merge and configure strict
Actions-bound protection for the exact full shell family. Replace the
historical partial shell set, verify the API readback, synchronize, and clean.

---

### Task 6: Update `hive-memory`

**Files:**

- Modify: `.github/workflows/ci.yml`

**Interfaces:**

- Consumes: `shell-ci.yml@a3ccc9312378c38a9d33074ea021f96ce93bfb84`

- Produces: the full `shell / Platforms / ...` family while retaining Rust,
  Android, performance, and cloud-sync jobs

- [ ] **Step 1: Add the shell full matrix**

Add `matrix-set: full` only under `jobs.shell.with`. Do not alter `jobs.rust`,
`termux-command`, `termux-host-command`, `performance-budget`, or
`cloud-sync-sim`.

- [ ] **Step 2: Validate**

Run:

```bash
actionlint .github/workflows/ci.yml
tests/shell/release-scripts-test
cargo test --locked
git diff --check
```

Expected: all commands exit zero.

- [ ] **Step 3: Ship**

Commit only the workflow, push explicitly, open the PR, and wait for every
existing required non-shell job plus the full shell matrix.

- [ ] **Step 4: Land and protect**

Squash-merge when green. Retain `Cloud sync simulation`, `Performance budget`,
the existing Rust quality/platform checks, and add the complete nine-context
shell family. Set strict mode and Actions bindings, verify, synchronize, and
clean.

---

### Task 7: Update `sley`

**Files:**

- Modify: `.github/workflows/test.yml`

**Interfaces:**

- Consumes: `shell-ci.yml@7d88c3afa6e51a83e9cfefb0c12f503155e17952`

- Produces: the full `shell / Platforms / ...` context family

- [ ] **Step 1: Add and validate the full matrix**

Add `matrix-set: full` under `jobs.shell.with`, retaining all profiles and
`test/sley-test`. Run:

```bash
actionlint .github/workflows/test.yml
test/sley-test
git diff --check
```

Expected: all commands exit zero.

- [ ] **Step 2: Ship, land, and protect**

Commit only the workflow, push explicitly, open the PR, wait for all nine
shell contexts, squash-merge, and configure strict Actions-bound protection
for the full family. Verify, synchronize, and clean.

---

### Task 8: Update `termnav`

**Files:**

- Modify: `.github/workflows/test.yml`

**Interfaces:**

- Consumes: `shell-ci.yml@7d88c3afa6e51a83e9cfefb0c12f503155e17952`

- Produces: the full `shell / Platforms / ...` family while retaining the
  independent current-eza compatibility job

- [ ] **Step 1: Add the full matrix**

Add `matrix-set: full` under `jobs.shell.with`. Preserve every dependency
profile, `test/termnav-test`, and `eza-current`.

- [ ] **Step 2: Validate**

Run:

```bash
actionlint .github/workflows/test.yml
test/termnav-test
git diff --check
```

Expected: all commands exit zero.

- [ ] **Step 3: Ship, land, and protect**

Commit only the workflow, push explicitly, open the PR, and wait for the
complete current-head workflow. Squash-merge when green; require the strict,
Actions-bound full shell context family while retaining any existing
non-shell requirement. Verify, synchronize, and clean.

---

### Task 9: Update `tmux-tools`

**Files:**

- Modify: `.github/workflows/test.yml`

**Interfaces:**

- Consumes: `shell-ci.yml@7d88c3afa6e51a83e9cfefb0c12f503155e17952`

- Produces: the full `shell / Platforms / ...` context family

- [ ] **Step 1: Add and validate the full matrix**

Add `matrix-set: full` under `jobs.shell.with`, retaining base, ShellCheck,
tmux, and `test/run`. Run:

```bash
actionlint .github/workflows/test.yml
test/run
git diff --check
```

Expected: all commands exit zero.

- [ ] **Step 2: Ship, land, and protect**

Commit only the workflow, push explicitly, open the PR, wait for all nine
contexts, squash-merge, and replace the partial historical shell gate with
the strict Actions-bound full family. Verify, synchronize, and clean.

---

### Task 10: Update `grafhome-ca`

**Files:**

- Modify: `.github/workflows/ci.yml`

**Interfaces:**

- Consumes: `shell-ci.yml@a3ccc9312378c38a9d33074ea021f96ce93bfb84`

- Produces: the full `shell / Platforms / ...` family while retaining MSRV,
  Rust/Android, SSH revocation, and Step CA integration jobs

- [ ] **Step 1: Add the shell full matrix**

Add `matrix-set: full` only under `jobs.shell.with`. Do not alter the Rust
reusable workflow, Android inputs, MSRV, SSH revocation, Step CA integration,
or release workflow.

- [ ] **Step 2: Validate**

Run:

```bash
actionlint .github/workflows/ci.yml
tests/shell/release-scripts-test
cargo test --locked
git diff --check
```

Expected: all commands exit zero.

- [ ] **Step 3: Ship**

Commit only the workflow, push explicitly, open the PR, and wait for the
complete current-head CI run.

- [ ] **Step 4: Land and protect**

Squash-merge only when green. Preserve `Step CA Integration / Ubuntu`, Rust
quality/platform checks, SSH revocation or other currently required
specialized checks, and require the full nine-context shell family. Set
strict mode and Actions bindings, verify, synchronize, and clean.

---

### Task 11: Portfolio Verification

**Files:**

- No repository files

**Interfaces:**

- Consumes: merged default branches and branch-protection APIs for all ten
  repositories

- Produces: final evidence that workflow and enforcement state agree

- [ ] **Step 1: Verify workflow state**

For every repository, fetch `origin/main` and verify every `shell-ci.yml`
caller contains `matrix-set: full`. Verify immutable refs and existing
Android/Termux configuration are unchanged.

- [ ] **Step 2: Verify protection state**

Read every `main` required-status configuration. Confirm `strict: true`, the
expected full shell context family or families, preserved specialized checks,
and the GitHub Actions app ID on every check.

- [ ] **Step 3: Verify cleanup**

Confirm every rollout PR is merged, every remote feature branch is deleted,
local `main` matches `origin/main`, and only unrelated pre-existing worktrees
remain.
