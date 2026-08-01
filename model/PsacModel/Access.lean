import PsacModel.Basic

/-!
Policy-gated provenance: the runtime's `explain :readable` (CL) / `explain(readable=...)`
(pypsac) descends the derivation only through locations the caller may read and
truncates at the access boundary with a `redacted` marker.

Two guarantees:
* `explain_mentions_readable` — no unreadable location (hence no unreadable name or
  value) ever appears in an answer;
* `explain_no_leak` — the answer is a function of the *readable projection* of the
  final store: runs agreeing on every readable location produce identical explanations,
  so a redacted answer carries no information about unreadable values.

Scope: program topology is public in this model. The runtimes additionally collapse a
node's redacted dependencies into a single marker so sibling counts do not leak; the
collapse only discards information, so both theorems transfer a fortiori.
-/

namespace PsacModel

/-- Depth-bounded explanation tree; `redacted` marks the access boundary. -/
inductive Expl where
  | redacted
  | input (x : String) (v : Int)
  | pruned (x : String) (v : Int)
  | node (x : String) (v : Int) (a b : Expl)
  deriving Repr, DecidableEq

/-- Explanation walk over the *reversed* program (head = last node executed),
reporting values from the final store `τ`; `r` is the caller's readability. -/
def explainAux (r : String → Bool) (τ : Store) : List Node → Nat → String → Expl
  | [], _, x => if r x then .input x (τ x) else .redacted
  | n :: rest, d, x =>
    if r x then
      if x = n.out then
        match d with
        | 0 => .pruned x (τ x)
        | d + 1 => .node x (τ x) (explainAux r τ rest d n.in1) (explainAux r τ rest d n.in2)
      else explainAux r τ rest d x
    else .redacted

/-- Policy-gated explanation of location `x` after running `p` from `σ`. -/
def explain (r : String → Bool) (σ : Store) (p : List Node) (d : Nat) (x : String) : Expl :=
  explainAux r (eval σ p) p.reverse d x

/-- Locations appearing (with their values) in an explanation. -/
def Expl.mentions : Expl → String → Prop
  | .redacted, _ => False
  | .input x _, y => y = x
  | .pruned x _, y => y = x
  | .node x _ a b, y => y = x ∨ a.mentions y ∨ b.mentions y

theorem explainAux_mentions_readable (r : String → Bool) (τ : Store) :
    ∀ (rev : List Node) (d : Nat) (x y : String),
      (explainAux r τ rev d x).mentions y → r y = true := by
  intro rev
  induction rev with
  | nil =>
    intro d x y h
    by_cases hx : r x = true
    · simp only [explainAux, if_pos hx, Expl.mentions] at h
      exact h ▸ hx
    · simp [explainAux, hx, Expl.mentions] at h
  | cons n rest ih =>
    intro d x y h
    by_cases hx : r x = true
    · simp only [explainAux, if_pos hx] at h
      by_cases hout : x = n.out
      · rw [if_pos hout] at h
        cases d with
        | zero =>
          simp only [Expl.mentions] at h
          exact h ▸ hx
        | succ d =>
          simp only [Expl.mentions] at h
          rcases h with h | h | h
          · exact h ▸ hx
          · exact ih d n.in1 y h
          · exact ih d n.in2 y h
      · rw [if_neg hout] at h
        exact ih d x y h
    · simp [explainAux, hx, Expl.mentions] at h

theorem explainAux_no_leak (r : String → Bool) (τ τ' : Store)
    (hagree : ∀ y, r y = true → τ y = τ' y) :
    ∀ (rev : List Node) (d : Nat) (x : String),
      explainAux r τ rev d x = explainAux r τ' rev d x := by
  intro rev
  induction rev with
  | nil =>
    intro d x
    by_cases hx : r x = true
    · simp [explainAux, hx, hagree x hx]
    · simp [explainAux, hx]
  | cons n rest ih =>
    intro d x
    by_cases hx : r x = true
    · by_cases hout : x = n.out
      · subst hout
        cases d with
        | zero => simp [explainAux, hx, hagree n.out hx]
        | succ d => simp [explainAux, hx, hagree n.out hx, ih d n.in1, ih d n.in2]
      · simp [explainAux, hx, hout, ih d x]
    · simp [explainAux, hx]

/-- No unreadable location — hence no unreadable name or value — appears in an answer. -/
theorem explain_mentions_readable (r : String → Bool) (σ : Store) (p : List Node)
    (d : Nat) (x y : String) (h : (explain r σ p d x).mentions y) : r y = true :=
  explainAux_mentions_readable r (eval σ p) p.reverse d x y h

/-- Redacted explanations are a function of the readable layer alone: runs agreeing on
every readable location give byte-identical answers, whatever the unreadable values. -/
theorem explain_no_leak (r : String → Bool) (σ σ' : Store) (p : List Node)
    (hagree : ∀ y, r y = true → eval σ p y = eval σ' p y) (d : Nat) (x : String) :
    explain r σ p d x = explain r σ' p d x :=
  explainAux_no_leak r (eval σ p) (eval σ' p) hagree p.reverse d x

end PsacModel
