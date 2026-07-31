import PsacModel.Basic

/-!
Why-provenance: `support p x` is the backward slice of location `x` through program `p`
down to input locations. `support_sound`: stores agreeing on the support agree on the
output.

Scope: this is the *data-dependence* slice of straight-line binary programs. The CL
runtime's `psac:support` additionally walks control dependence (ancestor read sets of
nested `adaptive-read`s); on flat graphs like the harness's the two coincide, but the
control-dependence part is covered by the test suite, not by this proof. Selective
(`:provenance`) slices are likewise out of scope — they explain the current value only.
-/

namespace PsacModel

/-- Backward slice over the *reversed* program (head = last node executed). -/
def supportAux : List Node → String → List String
  | [], x => [x]
  | n :: rest, x =>
    if x = n.out then supportAux rest n.in1 ++ supportAux rest n.in2
    else supportAux rest x

def support (p : List Node) (x : String) : List String :=
  supportAux p.reverse x

theorem supportAux_sound :
    ∀ (rev : List Node) (x : String) (σ σ' : Store),
      (∀ y ∈ supportAux rev x, σ y = σ' y) →
      eval σ rev.reverse x = eval σ' rev.reverse x := by
  intro rev
  induction rev with
  | nil =>
    intro x σ σ' h
    exact h x (by simp [supportAux])
  | cons n rest ih =>
    intro x σ σ' h
    have hrev : (n :: rest).reverse = rest.reverse ++ [n] := by simp
    rw [hrev, eval_append, eval_append]
    show step (eval σ rest.reverse) n x = step (eval σ' rest.reverse) n x
    by_cases hx : x = n.out
    · simp only [supportAux, if_pos hx] at h
      have h1 : ∀ y ∈ supportAux rest n.in1, σ y = σ' y :=
        fun y hy => h y (List.mem_append_left _ hy)
      have h2 : ∀ y ∈ supportAux rest n.in2, σ y = σ' y :=
        fun y hy => h y (List.mem_append_right _ hy)
      simp [step, Store.set, hx, ih n.in1 σ σ' h1, ih n.in2 σ σ' h2]
    · simp only [supportAux, if_neg hx] at h
      have := ih x σ σ' h
      simp [step, Store.set, hx, this]

/-- Locations outside the support cannot influence the result. -/
theorem support_sound (p : List Node) (x : String) (σ σ' : Store)
    (h : ∀ y ∈ support p x, σ y = σ' y) : eval σ p x = eval σ' p x := by
  have := supportAux_sound p.reverse x σ σ' (by simpa [support] using h)
  simpa using this

end PsacModel
