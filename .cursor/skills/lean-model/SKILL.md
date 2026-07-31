---
name: lean-model
description: >-
  The Lean 4 model of psac (model/PsacModel): which theorem backs which runtime
  mechanism, how to build with lake, the oracle executable, and the rules for keeping
  CL semantics and Lean proofs in sync. Use when changing propagation, cost, scenario,
  or parallel semantics, or when editing anything under model/.
---

# psac Lean model

Straight-line SSA node programs over `Store := String → Int`. The proofs cover the
idealized trace semantics; that the runtime establishes their premises (heights,
single-writer discipline) is covered by the Rove suite and the differential harness —
keep docs honest about this split.

## Theorem ↔ runtime map

| Runtime mechanism (CL) | Theorem | File |
|---|---|---|
| `propagate!` + equality cutoff | `propagate_correct` | `Basic.lean` |
| `support` (full, non-selective slice) | `support_sound` | `Support.lean` |
| `charge!` split (remainder → lowest id) | `charge_conserves`, `bill_conserves` | `Cost.lean` |
| `propagate-parallel!` waves, `par` | `step_comm`, `eval_perm`, `eval_blocks_comm`, `propagate_waves_correct` | `ParLevel.lean` |
| `with-scenario` / `what-if` | `scenario_observe`, `scenario_roundtrip`, `scenario_private` | `Scenario.lean` |

**Selective** provenance (`:provenance` fns) is *not* covered by `support_sound` — it
explains the current value only; never claim it bounds influence.

## Sync rules

- Change CL semantics → change the matching `.lean` file in the same commit and run the
  differential harness. **No `sorry`s**, ever.
- New harness op: add to `*harness-ops*` (`src/harness.lisp`) **and** `Op`/`parseOp`
  (`Basic.lean` / `Main.lean`); ops are binary, `Int → Int → Int`.
- The oracle (`Main.lean`) evaluates scenarios from scratch and cross-checks its own
  `propagate` per step — output must match the CL runtime's JSON **byte-for-byte**
  (key order is sorted names; no whitespace).

## Build

```bash
cd model && lake build            # proofs
lake build oracle                 # executable → .lake/build/bin/oracle
bash ../scripts/diff-test.sh      # CL vs Lean over scenarios/*.json
```

Toolchain pinned by `model/lean-toolchain` (elan). No elan on this host — use the
devcontainer or let CI run it; Lean-only changes still need `lake build` before merge.
