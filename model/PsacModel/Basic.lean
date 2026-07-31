/-!
Trace semantics for the psac sequential core.

Programs are straight-line SSA lists of binary nodes over `Store := String → Int`.
`eval` is the from-scratch semantics; `propagate` is change propagation reusing the
old run's outputs when a node's inputs are unchanged (the CL runtime's equality cutoff).

Main theorem: `propagate_correct` — propagating from any consistent old run equals
a from-scratch run on the new inputs.
-/

namespace PsacModel

inductive Op
  | add | sub | mul | max | min
  deriving Repr, DecidableEq

def Op.denote : Op → Int → Int → Int
  | .add, a, b => a + b
  | .sub, a, b => a - b
  | .mul, a, b => a * b
  | .max, a, b => Max.max a b
  | .min, a, b => Min.min a b

structure Node where
  op : Op
  in1 : String
  in2 : String
  out : String
  deriving Repr

abbrev Store := String → Int

def Store.set (σ : Store) (x : String) (v : Int) : Store :=
  fun y => if y = x then v else σ y

@[simp] theorem Store.set_same (σ : Store) (x : String) (v : Int) :
    (σ.set x v) x = v := by
  simp [Store.set]

theorem Store.set_other (σ : Store) {x y : String} (v : Int) (h : y ≠ x) :
    (σ.set x v) y = σ y := by
  simp [Store.set, h]

def step (σ : Store) (n : Node) : Store :=
  σ.set n.out (n.op.denote (σ n.in1) (σ n.in2))

def eval (σ : Store) (p : List Node) : Store :=
  p.foldl step σ

@[simp] theorem eval_nil (σ : Store) : eval σ [] = σ := rfl

@[simp] theorem eval_cons (σ : Store) (n : Node) (p : List Node) :
    eval σ (n :: p) = eval (step σ n) p := rfl

theorem eval_append (σ : Store) (p q : List Node) :
    eval σ (p ++ q) = eval (eval σ p) q := by
  simp [eval, List.foldl_append]

/-- Change propagation step: recompute only when an input differs from the old run. -/
def propStep (σold : Store) (σ : Store) (n : Node) : Store :=
  if σ n.in1 = σold n.in1 ∧ σ n.in2 = σold n.in2 then
    σ.set n.out (σold n.out)
  else
    step σ n

def propagate (σold σ : Store) (p : List Node) : Store :=
  p.foldl (propStep σold) σ

/-- Straight-line SSA well-formedness: a node does not rewrite its own inputs, and later
nodes touch neither its inputs nor its output. -/
inductive WF : List Node → Prop
  | nil : WF []
  | cons {n : Node} {p : List Node} :
      n.out ≠ n.in1 → n.out ≠ n.in2 →
      (∀ m ∈ p, m.out ≠ n.in1 ∧ m.out ≠ n.in2 ∧ m.out ≠ n.out) →
      WF p → WF (n :: p)

/-- Locations never written by a program keep their value. -/
theorem eval_preserves {x : String} :
    ∀ {p : List Node}, (∀ m ∈ p, m.out ≠ x) → ∀ σ : Store, eval σ p x = σ x := by
  intro p
  induction p with
  | nil => intro _ σ; rfl
  | cons n p ih =>
    intro h σ
    have hn : n.out ≠ x := h n (List.mem_cons_self n p)
    have hp : ∀ m ∈ p, m.out ≠ x := fun m hm => h m (List.mem_cons_of_mem n hm)
    rw [eval_cons, ih hp]
    exact Store.set_other σ _ (Ne.symm hn)

/-- Change propagation from a consistent old run computes the from-scratch result. -/
theorem propagate_correct : ∀ {p : List Node}, WF p →
    ∀ σ₀ σ₁ : Store, propagate (eval σ₀ p) σ₁ p = eval σ₁ p := by
  intro p hwf
  induction hwf with
  | nil => intro _ _; rfl
  | @cons n p hn1 hn2 hlater _ ih =>
    intro σ₀ σ₁
    have h1 : ∀ m ∈ p, m.out ≠ n.in1 := fun m hm => (hlater m hm).1
    have h2 : ∀ m ∈ p, m.out ≠ n.in2 := fun m hm => (hlater m hm).2.1
    have h3 : ∀ m ∈ p, m.out ≠ n.out := fun m hm => (hlater m hm).2.2
    have hin1 : eval (step σ₀ n) p n.in1 = σ₀ n.in1 := by
      rw [eval_preserves h1]
      exact Store.set_other σ₀ _ (Ne.symm hn1)
    have hin2 : eval (step σ₀ n) p n.in2 = σ₀ n.in2 := by
      rw [eval_preserves h2]
      exact Store.set_other σ₀ _ (Ne.symm hn2)
    have hout : eval (step σ₀ n) p n.out = n.op.denote (σ₀ n.in1) (σ₀ n.in2) := by
      rw [eval_preserves h3]
      simp [step]
    have key : propStep (eval (step σ₀ n) p) σ₁ n = step σ₁ n := by
      by_cases hcond : σ₁ n.in1 = eval (step σ₀ n) p n.in1 ∧ σ₁ n.in2 = eval (step σ₀ n) p n.in2
      · have e1 : σ₁ n.in1 = σ₀ n.in1 := hcond.1.trans hin1
        have e2 : σ₁ n.in2 = σ₀ n.in2 := hcond.2.trans hin2
        simp [propStep, hcond, step, hout, e1, e2]
      · simp [propStep, hcond]
    calc propagate (eval σ₀ (n :: p)) σ₁ (n :: p)
        = propagate (eval (step σ₀ n) p) (propStep (eval (step σ₀ n) p) σ₁ n) p := rfl
      _ = propagate (eval (step σ₀ n) p) (step σ₁ n) p := by rw [key]
      _ = eval (step σ₁ n) p := ih (step σ₀ n) (step σ₁ n)
      _ = eval σ₁ (n :: p) := rfl

end PsacModel
