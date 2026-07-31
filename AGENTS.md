# Agent instructions

Act as a **senior Common Lisp developer**: idiomatic code (ASDF systems, packages, conditions),
clear abstractions, no cleverness without payoff.

## Stack

SBCL via **Roswell**, deps pinned with **qlot** (`qlfile.lock`), tests in **Rove**,
formal model in **Lean 4** (`model/`), everything reproducible in the **devcontainer**
(`ghcr.io/egao1980/features/roswell:1`). Skills for specialized work live in
`.cursor/skills/` — read the one whose `description` matches the task before starting.

## Project invariants (do not break)

- **Claims are backed.** Every mechanism claim in `README.md` / `docs/portfolio-demo.md`
  is backed by a test or a Lean theorem. State the honest scope: Lean proves the
  idealized trace semantics; the runtime establishing its premises is covered by the
  test suite and the differential harness.
- **CL and Lean stay in sync.** Semantics changes (cutoff, propagation order, cost
  split, scenario semantics, wave scheduling) must touch the corresponding
  `model/PsacModel/*.lean` file and pass `scripts/diff-test.sh`. No `sorry`s.
- **Docs' worked numbers are real.** The bills/charges in `docs/portfolio-demo.md` must
  match `(psac:run-portfolio-demo)` output exactly; regenerate `portfolio-demo.pdf`
  when the `.md` changes.
- **No new global mutable state.** All mutable runtime state lives in special variables
  rebound by `with-fresh-state` (and destructively cleared by `reset-all!`). If you add
  a stateful defvar, add it to both. Tests use `deftest-fresh`, never raw globals.
- **Concurrency discipline.** Single writer per mod; shared-graph mutation goes through
  `with-graph-lock`; any special variable read inside worker-executed code must be
  conveyed explicitly to lparallel tasks (futures do not inherit dynamic bindings).

## Git

Feature branches; small milestone commits; undo with git (`git restore` / `revert`),
never from memory. Remote is `github.com/egao1980/psac`.

## Verification

Run the Rove suite after substantive edits; run the demo when touching `portfolio.lisp`
or billing; run the differential harness when touching semantics. See
`.cursor/skills/run-psac-tests/SKILL.md` for exact commands (including the host/WSL
fallback when the devcontainer is unavailable).
