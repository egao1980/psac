/-!
Cost attribution: a re-executed node's cost is split among the principals in its blame
set by integer division, remainder to the first (lowest) principal — exactly the rule in
src/cost.lisp. `bill_conserves`: attributed costs sum to the total re-execution work.
-/

import PsacModel.Basic

namespace PsacModel

/-- Split COST among BLAME principals: integer share each, remainder to the first. -/
def charge (cost : Nat) (blame : List Nat) : List (Nat × Nat) :=
  match blame with
  | [] => []
  | p :: rest =>
    (p, cost / (rest.length + 1) + cost % (rest.length + 1)) ::
      rest.map (fun q => (q, cost / (rest.length + 1)))

theorem sum_map_const {α : Type _} (l : List α) (c : Nat) :
    (l.map (fun _ => c)).sum = l.length * c := by
  induction l with
  | nil => simp
  | cons a l ih => simp [ih, Nat.succ_mul, Nat.add_comm]

theorem charge_conserves (cost : Nat) (blame : List Nat) (h : blame ≠ []) :
    ((charge cost blame).map Prod.snd).sum = cost := by
  match blame with
  | [] => exact absurd rfl h
  | p :: rest =>
    simp [charge, List.map_map, Function.comp, sum_map_const]
    have hsm : (rest.length + 1) * (cost / (rest.length + 1)) =
        rest.length * (cost / (rest.length + 1)) + cost / (rest.length + 1) :=
      Nat.succ_mul _ _
    have hdm := Nat.div_add_mod cost (rest.length + 1)
    rw [hsm] at hdm
    generalize rest.length * (cost / (rest.length + 1)) = w at hdm ⊢
    omega

/-- One re-executed node in an update log. -/
structure Exec where
  cost : Nat
  blame : List Nat

def totalCost (log : List Exec) : Nat :=
  (log.map (·.cost)).sum

def bills (log : List Exec) : List (Nat × Nat) :=
  log.flatMap (fun e => charge e.cost e.blame)

/-- Attribution is exactly conserved over a whole propagation. -/
theorem bill_conserves (log : List Exec) (h : ∀ e ∈ log, e.blame ≠ []) :
    ((bills log).map Prod.snd).sum = totalCost log := by
  induction log with
  | nil => rfl
  | cons e log ih =>
    have he : e.blame ≠ [] := h e (List.mem_cons_self e log)
    have hl : ∀ x ∈ log, x.blame ≠ [] := fun x hx => h x (List.mem_cons_of_mem e hx)
    simp only [bills, totalCost, List.flatMap_cons, List.map_cons, List.map_append,
               List.sum_append, List.sum_cons]
    rw [charge_conserves e.cost e.blame he]
    have := ih hl
    simp only [bills, totalCost] at this
    rw [this]

end PsacModel
