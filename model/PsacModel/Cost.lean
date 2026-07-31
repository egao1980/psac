import PsacModel.Basic

/-!
Cost attribution: a re-executed node's cost is split among the principals in its blame
set by integer division, remainder to the first principal — the rule in src/cost.lisp.

CL blame is a fixnum bitmask walked low→high, so blame lists here are strictly
ascending: duplicate-free (`blame_nodup`) and headed by the lowest principal id
(`blame_head_lowest`) — "remainder to the first" and CL's "remainder to the lowest id"
coincide. Empty blame (CL: the whole cost goes to `:system`) is a single-recipient
charge outside the split; here `charge cost [] = []` and `charge_conserves` requires a
non-empty blame set.

`bill_conserves`: attributed costs sum to the total re-execution work.
-/

namespace PsacModel

/-- Split COST among BLAME principals: integer share each, remainder to the first
(= lowest id, since blame lists mirror the CL bitmask's ascending walk). -/
def charge (cost : Nat) (blame : List Nat) : List (Nat × Nat) :=
  match blame with
  | [] => []
  | p :: rest =>
    (p, cost / (rest.length + 1) + cost % (rest.length + 1)) ::
      rest.map (fun q => (q, cost / (rest.length + 1)))

/-- Strictly ascending blame lists (the bitmask walk) carry no duplicate principals. -/
theorem blame_nodup {blame : List Nat} (h : blame.Pairwise (· < ·)) : blame.Nodup :=
  h.imp fun hlt => Nat.ne_of_lt hlt

/-- With blame strictly ascending, the head — which `charge` hands the remainder —
is the lowest principal id, matching CL's remainder-to-lowest rule. -/
theorem blame_head_lowest {p : Nat} {rest : List Nat}
    (h : (p :: rest).Pairwise (· < ·)) : ∀ q ∈ p :: rest, p ≤ q := by
  intro q hq
  rcases List.mem_cons.mp hq with heq | hmem
  · exact Nat.le_of_eq heq.symm
  · exact Nat.le_of_lt ((List.pairwise_cons.mp h).1 q hmem)

theorem sum_append (l r : List Nat) : (l ++ r).sum = l.sum + r.sum := by
  induction l with
  | nil => simp
  | cons a l ih => simp [ih, Nat.add_assoc]

theorem sum_map_const {α : Type _} (l : List α) (c : Nat) :
    (l.map (fun _ => c)).sum = l.length * c := by
  induction l with
  | nil => simp
  | cons a l ih => simp [ih, Nat.succ_mul, Nat.add_comm]

/-- A single node's cost is exactly conserved by the split. -/
theorem charge_conserves (cost : Nat) (blame : List Nat) (h : blame ≠ []) :
    ((charge cost blame).map Prod.snd).sum = cost := by
  match blame with
  | [] => exact absurd rfl h
  | p :: rest =>
    have hmap : ((rest.map (fun q => (q, cost / (rest.length + 1)))).map Prod.snd)
        = rest.map (fun _ => cost / (rest.length + 1)) := by
      rw [List.map_map]
      simp [Function.comp]
    simp only [charge, List.map_cons, List.sum_cons, hmap, sum_map_const]
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

def totalCost : List Exec → Nat
  | [] => 0
  | e :: log => e.cost + totalCost log

def bills : List Exec → List (Nat × Nat)
  | [] => []
  | e :: log => charge e.cost e.blame ++ bills log

/-- Attribution is exactly conserved over a whole propagation. -/
theorem bill_conserves (log : List Exec) (h : ∀ e ∈ log, e.blame ≠ []) :
    ((bills log).map Prod.snd).sum = totalCost log := by
  induction log with
  | nil => rfl
  | cons e log ih =>
    have he : e.blame ≠ [] := h e (List.mem_cons_self e log)
    have hl : ∀ x ∈ log, x.blame ≠ [] := fun x hx => h x (List.mem_cons_of_mem e hx)
    show ((charge e.cost e.blame ++ bills log).map Prod.snd).sum = e.cost + totalCost log
    rw [List.map_append, sum_append, charge_conserves e.cost e.blame he, ih hl]

end PsacModel
