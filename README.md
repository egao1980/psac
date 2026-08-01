# psac

[![100% AI Generated](https://img.shields.io/badge/100%25-AI%20Generated-black)](https://github.com/egao1980/psac)

Self-adjusting computation (SAC) in Common Lisp with cost attribution, provenance-based explanation,
and access rights expressed as SAC — paired with a Lean 4 model of the trace semantics.

Concept follows Anderson, Blelloch, Baweja & Acar, *Efficient Parallel Self-Adjusting Computation*
(SPAA '21, [doi:10.1145/3409964.3461799](https://doi.org/10.1145/3409964.3461799)). The runtime covers
the sequential core plus a parallel one: level-synchronous change propagation (`propagate-parallel!`)
and fork-join inside computations (`par`, `par-map`) on an lparallel work-stealing kernel — both
~6.3x on 8 workers and proof-backed (`model/PsacModel/ParLevel.lean`). Full timestamped RSP trees
are intentionally out of scope: computation topology is static per universe (see Design notes).

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

- **Propagation**: dirty R-nodes processed in (stratum, height) order (bucketed by level, minimal
  bucket found via a lazy min-heap of keys — O(log #levels) even when dirt spans many levels);
  equality cutoff on `write!`. Height-based glitch-free ordering (Jane Street Incremental style).
- **Static topology by design**: node read sets are fixed at creation, so heights are computed once
  and never re-leveled — this is an assumption, not a bug: topology changes are either *additive*
  (new nodes over live mods, see `adaptive-forest` below) or done by building a fresh universe
  (universes coexist in one graph; see the multi-universe test and `with-fresh-state`). A graph that
  breaks the assumption (a write installing a writer at or above a same-stratum reader) signals a
  continuable `height-invariant-error` instead of silently glitching. Timestamped RSP traces, which
  would lift the assumption, are intentionally out of scope.
- **Dynamic membership** (`adaptive-forest`, `make-dynamic-book` / `add-asset!`): aggregates over a
  growing set are shaped like a persistent data structure — a binary-counter forest of perfect
  reduction trees. Insertion is path copying, not mutation: O(log n) *new* nodes (amortized O(1))
  over live mods, no existing node re-registered or re-executed, sibling subtrees physically reused
  (trace, provenance and all), and consumers hold one stable total mod across insertions. This is
  reuse-by-structure — the part of SAC memoization these workloads need without RSP timestamps.
  Removal stays non-structural (trade to qty 0). `(psac:run-dynamic-book-demo)` walks through it.
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
- **Parallelism is proof-backed** (`model/PsacModel/ParLevel.lean`): the scheduler only reorders
  independent nodes, so correctness reduces to commutation — `step_comm` (independent steps commute),
  `eval_perm` (pairwise-independent lists are permutation-invariant, i.e. wave workers may commit in
  any order), `eval_blocks_comm` (fork-join branch blocks swap), and `propagate_waves_correct`
  (propagating in any level-synchronous wave order from a consistent run equals from-scratch).
  `Indep` is the semantic counterpart of the runtime's height invariant; that the implementation
  establishes it is covered by the test suite and differential harness, not the proofs.
- **Cost**: attributed per re-executed R-node to the *blame set* (principals whose writes caused the re-run).
  Batched deltas split cost by integer division, remainder to the lowest principal id — exact conservation,
  proved in `model/PsacModel/Cost.lean` (`charge_conserves` / `bill_conserves`; blame lists mirror the
  bitmask's ascending walk, so remainder-to-first *is* remainder-to-lowest — `blame_head_lowest`).
- **Provenance**: `support` (backward slice, control + data dependence), `explain-update` (last propagation's
  causal chain), `probe` (counterfactuals via propagate-and-rollback). Selective-provenance combinators
  (`:provenance` on `adaptive-read`) sharpen `max`-like ops to their argmax witnesses (all of them, under
  ties). Note the scope of the guarantee: `support_sound` (Lean) covers the full, non-selective *data* slice
  on the straight-line model — inputs outside it cannot change the value; the control-dependence part of
  the runtime's `support` (ancestor read sets of nested reads) is covered by the test suite, not the proof.
  Selective slices explain the current value only; they do not
  bound influence (for a max, any input rising above the current value would change it).
- **Policy-gated provenance**: `explain` takes a `:readable` predicate and descends only while every
  mod on the path is readable by the caller, collapsing anything beyond the boundary into a single
  `(:redacted t)` entry — no names, values, or branch counts leak. `explain-view` (portfolio) wires
  the predicate to the self-adjusting `allowed-mod` decisions, so a revocation truncates provenance
  answers on the next propagate; an unreadable root answers `:denied` like `request`. Lean
  (`model/PsacModel/Access.lean`): `explain_mentions_readable` (no unreadable location appears in an
  answer) and `explain_no_leak` (answers are a function of the readable projection of the store
  alone). Bare `support` / `derivation-slice` stay unfiltered on purpose — they are trusted-context
  APIs for billing and reports.
- **Scenarios** (tagged / private / as-if updates): `with-scenario` + `scenario-write!` +
  `scenario-propagate!` run a named batch of hypothetical writes against the live graph and roll it
  back on exit (normal or non-local); `what-if` is the multi-write `probe`. Private: the base
  universe, `*last-bill*` and `*last-update-log*` are untouched — hypothetical recompute cost lands
  on the scenario's own bill, blamed on the scenario owner, retrievable by tag (`find-scenario`,
  `scenario-bill-alist`, `scenario-explain`). Scenarios nest LIFO. Lean counterparts in
  `model/PsacModel/Scenario.lean`: `scenario_observe` (as-if = from-scratch on the tagged world),
  `scenario_roundtrip` (rollback restores the base world exactly), `scenario_private` (a scenario
  writing outside an observer's support is invisible to that observer).
- **State**: all mutable runtime state (dirty queue, bills, logs, scenarios, policy and principal
  tables, counters) lives in special variables. `with-fresh-state` rebinds the lot to fresh objects
  with dynamic extent — globals untouched, bindings nest, and one `with-fresh-state` per thread gives
  fully isolated worlds that compute concurrently (`reset-all!` is the destructive counterpart; the
  test suite runs every test inside `with-fresh-state`). Parallel waves and `par` convey the
  coordinator's bindings to lparallel workers explicitly, since futures do not inherit specials.
- **Access**: read/write capabilities, fixnum-bitset label lattice (`*enforce-labels*`), policy-as-SAC:
  per-fact mods `member?(p,g)` / `grants(g,c)` at stratum 0 propagate before data, so revocation is just
  change propagation. `release-gated` demonstrates a differencing-resistant aggregate gate.
- **Lean model** (`model/`): straight-line SSA node programs over `Store := String → Int`.
  Theorems: `propagate_correct` (incremental = from-scratch), `support_sound`, cost conservation,
  the redaction guarantees in `Access.lean`, and the `ParLevel` commutation results above. The
  `oracle` executable evaluates scenarios from scratch and cross-checks its own `propagate`.

## Worked scenario: portfolio risk (`src/portfolio.lisp`)

A presentation-style walkthrough with diagrams, code fragments, and worked billing
numbers lives in [`docs/portfolio-demo.md`](docs/portfolio-demo.md)
([PDF](docs/portfolio-demo.pdf); rebuild with `scripts/build-docs.sh`).

`(psac:run-portfolio-demo)` — a book of positions priced off ticker mods owned by a market-data
feed, with adaptive risk views: per-asset P&L, firm P&L, desk P&L, gross exposure, and worst
position (selective provenance: the argmin position explains the number).

- **Access** (policy as SAC): Alice (group `:risk`) sees everything; Bob (group `:desk-b`) sees
  only his desk's aggregates — raw prices, per-position detail and firm-wide views answer
  `:denied`, and `revoke!` cuts him off by ordinary change propagation. `explain-view` extends the
  same policy to provenance queries: Bob's explanation of his desk P&L stops at the desk layer,
  with everything below collapsed into `(:redacted t)`.
- **Billing**, two channels: propagation bills blame whoever wrote (feed ticks, Alice's trades)
  for the nodes their change re-ran at each node's predefined `:cost`; `request` charges the
  caller a flat API fee plus source-data costs and calc costs summed over the provenance slice
  of the requested view — Bob's smaller slice makes his requests cheaper by construction.
- **Report**: `risk-report` explains Alice's numbers — per-position P&L attribution, why the
  worst position is what it is (selective provenance), the causal chain of the last update
  (which nodes re-ran, on whose blame, at what cost), and a counterfactual price-shock probe
  that leaves the world untouched.
