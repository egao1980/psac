---
name: devcontainer-ci
description: >-
  psac devcontainer and GitHub Actions CI: the roswell feature image, post-create
  behavior, running/debugging the ci.yml workflow, act limitations, and gh CLI
  monitoring. Use when editing .devcontainer/, .github/workflows/, or debugging CI.
---

# Devcontainer and CI

## Devcontainer

`mcr.microsoft.com/devcontainers/base:ubuntu` + `ghcr.io/egao1980/features/roswell:1`
(Roswell + SBCL + qlot; source: [egao1980/features](https://github.com/egao1980/features)).
`post-create.sh` runs `qlot install` (materializes `.qlot/` with symlinks into
`/home/vscode/.cache/qlot` — container-only paths) and installs Lean via elan, pinned by
`model/lean-toolchain`.

```bash
devcontainer up --workspace-folder .
devcontainer exec --workspace-folder . bash scripts/test.sh
```

Use the standalone `@devcontainers/cli` (`npx @devcontainers/cli`) — editor wrapper
binaries inject unsupported arguments.

## CI (`.github/workflows/ci.yml`)

Triggers on PRs and pushes to `main`; runs `test.sh`, `build-model.sh`, `diff-test.sh`
inside the devcontainer via `devcontainers/ci@v0.3` (`push: never`). A branch push alone
does **not** run CI — open a PR.

```bash
gh run list --repo egao1980/psac --limit 5
gh run view <run-id> --repo egao1980/psac --log-failed
gh run watch <run-id> --repo egao1980/psac
```

## Local workflow testing with act

- Jobs that only parse/validate run fine:
  `act -j test -n` (dry-run plan), `act pull_request -P ubuntu-latest=catthehacker/ubuntu:act-latest`.
- The `devcontainers/ci` action builds and runs a container **inside** act's container;
  Docker-out-of-Docker bind mounts fail from there. Don't debug that under act — run the
  devcontainer + scripts directly instead (that's exactly what CI does).

## Feature gotchas (from egao1980/features)

- `containerEnv` in a feature applies at **runtime**, not during `install.sh` builds —
  scripts must export PATH themselves (why `scripts/*.sh` prepend
  `$HOME/.roswell/bin:$HOME/.elan/bin`).
- First `devcontainer up` after a feature version bump re-downloads dists; slow is
  normal, hung usually means the SBCL debugger is waiting on stdin somewhere — check
  that every scripted `ros`/`sbcl` call is `--non-interactive`.
