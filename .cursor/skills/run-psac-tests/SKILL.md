---
name: run-psac-tests
description: >-
  Run the psac Rove test suite, a single test, the portfolio demo, or the CL-vs-Lean
  differential harness — in the devcontainer or via the host/WSL Roswell fallback.
  Use whenever verifying changes to src/, tests/, model/, or docs' worked numbers.
---

# Running psac tests

## Devcontainer (canonical)

```bash
devcontainer up --workspace-folder .
devcontainer exec --workspace-folder . bash scripts/test.sh        # Rove suite
devcontainer exec --workspace-folder . bash scripts/build-model.sh # Lean proofs + oracle
devcontainer exec --workspace-folder . bash scripts/diff-test.sh   # CL vs Lean, byte-for-byte
```

## Host fallback (Windows dev box: WSL Ubuntu + Roswell)

The in-repo `.qlot/` contains **symlinks into the devcontainer's `/home/vscode` cache**
and does not resolve on the host — do **not** `--load .qlot/setup.lisp` outside the
container. Use Roswell's own Quicklisp instead (deps: alexandria, com.inuoe.jzon,
bordeaux-threads, lparallel, rove — all in the standard dist):

```bash
wsl -d Ubuntu -- bash -lc "cd /mnt/c/Users/egao1/todos/psac && cat > /tmp/rt.lisp <<'EOF'
(push (uiop:getcwd) asdf:*central-registry*)
(ql:quickload :psac :silent t)
(ql:quickload :rove :silent t)
(asdf:load-system :psac/tests)
(uiop:quit (if (rove:run :psac/tests) 0 1))
EOF
ros run -- --non-interactive --eval '(ros:quicklisp)' --load /tmp/rt.lisp"
```

`/tmp` is per-WSL-session — recreate the driver file in the same invocation.
Windows-native `ros` exists but chokes on the Linux-built `.qlot`; prefer WSL.

## Pitfalls

- **Always `--non-interactive`** (or `sbcl --disable-debugger`): otherwise an unhandled
  condition drops into the interactive debugger and the process appears hung.
- **Single test:** replace the `rove:run` line with
  `(rove:run-test 'psac/tests::multi-universe)`.
- Tests are isolated via `deftest-fresh` (each runs in `with-fresh-state`); they must not
  depend on global interning order or leftover graph state.

## Demo / docs sync

When touching `portfolio.lisp`, billing, or provenance, run
`--eval '(psac:run-portfolio-demo)'` and diff against the output blocks in
`docs/portfolio-demo.md` — the worked numbers there are load-bearing documentation.
Regenerate `docs/portfolio-demo.pdf` when the `.md` changes.

## Differential harness

`scripts/diff-test.sh` needs both Roswell and Lean (elan/lake) — devcontainer or CI only
on this machine. CI (`.github/workflows/ci.yml`) runs all three scripts on PRs and
pushes to `main`.
