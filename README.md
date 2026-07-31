# psac

Self-adjusting computation (SAC) in Common Lisp with cost attribution, provenance-based explanation,
and access rights expressed as SAC — paired with a Lean 4 model of the trace semantics.

Concept follows Anderson, Blelloch, Baweja & Acar, *Efficient Parallel Self-Adjusting Computation*
(SPAA '21, [doi:10.1145/3409964.3461799](https://doi.org/10.1145/3409964.3461799)). This repo implements
the sequential core; the parallel runtime (RSP trees, work stealing) is a later phase.

## Layout

| Path | Contents |
|------|----------|
| `src/` | CL runtime: primitives (`make-mod`, `adaptive-read`, `write!`, `propagate!`), cost/blame, provenance, policy |
| `tests/` | rove test suite |
| `model/` | Lean 4 package `PsacModel`: trace semantics, propagation correctness, cost conservation, executable oracle |
| `scenarios/` | JSON scenarios for the CL-vs-Lean differential harness |
| `scripts/` | test and diff-harness entry points |

## Dev container

Everything runs in the dev container (Roswell + SBCL + qlot via `ghcr.io/egao1980/features/roswell:1`;
Lean via elan, pinned by `model/lean-toolchain`).

```bash
devcontainer up --workspace-folder .
devcontainer exec --workspace-folder . bash scripts/test.sh       # CL tests (rove)
devcontainer exec --workspace-folder . bash scripts/build-model.sh # Lean proofs + oracle
devcontainer exec --workspace-folder . bash scripts/diff-test.sh   # CL runtime vs Lean oracle
```

## Design notes

- **Propagation**: dirty R-nodes processed in (stratum, height) order; equality cutoff on `write!`.
  Height-based glitch-free ordering (Jane Street Incremental style); RSP timestamps arrive with the parallel phase.
- **Parallel propagation** (`propagate-parallel!`): level-synchronous waves on an lparallel kernel.
  By the height invariant, same-level dirty nodes never read each other's outputs, so each
  (stratum, height) level runs as one parallel wave with a barrier between levels. Graph bookkeeping
  is serialized by a lock taken only during waves; user thunks run unlocked. Bills stay deterministic
  (per-node blame; wave execution order only affects log order). `(psac:bench-parallel :n 64 :workers 8)`
  shows ~6x on heavy map nodes.
- **Fork-join inside computations** (`par`, `par-map`, RSP-lite): a thunk can split into two branches
  that run as lparallel futures (the kernel does work stealing internally), joining before the thunk
  continues — so a single R-node's (re-)execution is internally parallel and the trace records S/P
  structure (`:par` context on children). Dynamic state (bill, blame, labels) is conveyed to workers
  explicitly; granularity is defpun-style — spawning stops beyond `ceil(log2 workers)+2` nested `par`s
  (tunable via `*par-max-depth*`). `(psac:bench-par-within :n 64 :workers 8)` shows ~6x inside one
  node, where level parallelism can't help. Timestamped RSP trees with SP-order maintenance remain
  future work.
- **Cost**: attributed per re-executed R-node to the *blame set* (principals whose writes caused the re-run).
  Batched deltas split cost by integer division, remainder to the lowest principal id — exact conservation,
  proved in `model/PsacModel/Cost.lean`.
- **Provenance**: `support` (backward slice, control + data dependence), `explain-update` (last propagation's
  causal chain), `probe` (counterfactuals via propagate-and-rollback). Selective-provenance combinators
  (`:provenance` on `adaptive-read`) sharpen `max`-like ops to their argmax.
- **Access**: read/write capabilities, fixnum-bitset label lattice (`*enforce-labels*`), policy-as-SAC:
  per-fact mods `member?(p,g)` / `grants(g,c)` at stratum 0 propagate before data, so revocation is just
  change propagation. `release-gated` demonstrates a differencing-resistant aggregate gate.
- **Lean model** (`model/`): straight-line SSA node programs over `Store := String → Int`.
  Theorems: `propagate_correct` (incremental = from-scratch), `support_sound`, cost conservation.
  The `oracle` executable evaluates scenarios from scratch and cross-checks its own `propagate`.
