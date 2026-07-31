import PsacModel.Basic
import PsacModel.Support

/-!
Tagged ephemeral (as-if) updates: a scenario is a named batch of hypothetical input
writes. Its meaning over base inputs σ is the world `sc.world σ`.

* `scenario_observe` — reading a location after incrementally propagating the base run
  into the tagged world gives exactly the from-scratch value of that world;
* `scenario_roundtrip` — propagating back to the base inputs restores the base universe
  exactly (the CL runtime's `with-scenario` rollback);
* `scenario_private` — a scenario whose writes lie outside the support of an observer's
  location is invisible to that observer, tagged or not.
-/

namespace PsacModel

structure Scenario where
  tag : String
  writes : List (String × Int)

def applyWrites (σ : Store) : List (String × Int) → Store
  | [] => σ
  | (x, v) :: ws => applyWrites (σ.set x v) ws

/-- The hypothetical universe a scenario denotes over base inputs σ. -/
def Scenario.world (sc : Scenario) (σ : Store) : Store :=
  applyWrites σ sc.writes

/-- Locations no write targets are untouched by the batch. -/
theorem applyWrites_other :
    ∀ (ws : List (String × Int)) (σ : Store) (z : String),
      (∀ w ∈ ws, w.1 ≠ z) → applyWrites σ ws z = σ z := by
  intro ws
  induction ws with
  | nil => intro σ _ _; rfl
  | cons w ws ih =>
    intro σ z h
    obtain ⟨x, v⟩ := w
    show applyWrites (σ.set x v) ws z = σ z
    rw [ih (σ.set x v) z (fun w' hw' => h w' (List.mem_cons_of_mem _ hw'))]
    exact Store.set_other σ v (Ne.symm (h (x, v) (List.mem_cons_self (x, v) ws)))

/-- As-if observation: incremental propagation into the tagged world reads the
from-scratch value of that world. -/
theorem scenario_observe {p : List Node} (hwf : WF p) (σ : Store) (sc : Scenario)
    (x : String) :
    propagate (eval σ p) (sc.world σ) p x = eval (sc.world σ) p x := by
  rw [propagate_correct hwf σ (sc.world σ)]

/-- Rollback: propagating back to the base inputs restores the base universe exactly. -/
theorem scenario_roundtrip {p : List Node} (hwf : WF p) (σ : Store) (sc : Scenario) :
    propagate (propagate (eval σ p) (sc.world σ) p) σ p = eval σ p := by
  rw [propagate_correct hwf σ (sc.world σ), propagate_correct hwf (sc.world σ) σ]

/-- Privacy: a scenario writing only outside the support of y is invisible at y. -/
theorem scenario_private {p : List Node} (σ : Store) (sc : Scenario) (y : String)
    (h : ∀ w ∈ sc.writes, w.1 ∉ support p y) :
    eval (sc.world σ) p y = eval σ p y := by
  apply support_sound
  intro z hz
  exact applyWrites_other sc.writes σ z
    (fun w hw hne => h w hw (by rw [hne]; exact hz))

end PsacModel
