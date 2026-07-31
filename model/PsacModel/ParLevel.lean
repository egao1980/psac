import PsacModel.Basic

/-!
Order-irrelevance of independent nodes: the semantic justification for psac's parallel
change propagation (phase 7a, level-synchronous waves) and fork-join (phase 7b, `par`).

The scheduler never changes *what* runs, only the *order* in which independent nodes
commit, so correctness reduces to commutation:

* `step_comm` — independent steps commute (also the 7b fork-join branch case);
* `eval_perm` — evaluating a pairwise-independent list is permutation-invariant,
  so any order a wave's workers finish in yields the same store;
* `eval_blocks_comm` — two blocks touching disjoint locations run in either order
  (a `par` of independent branches);
* `waves_WF` — well-formedness of the canonical order carries over to any wave order;
* `propagate_waves_correct` — propagating in any level-synchronous wave order from a
  consistent old run computes the from-scratch result on the canonical program,
  assuming well-formedness only of the canonical order.

`Indep` is the semantic counterpart of the runtime's height invariant: dirty nodes at
the same (stratum, height) never read or write each other's locations.
-/

namespace PsacModel

/-- Nodes touching disjoint locations: neither writes what the other reads or writes. -/
def Indep (m n : Node) : Prop :=
  m.out ≠ n.in1 ∧ m.out ≠ n.in2 ∧ n.out ≠ m.in1 ∧ n.out ≠ m.in2 ∧ m.out ≠ n.out

theorem Indep.symm {m n : Node} (h : Indep m n) : Indep n m :=
  ⟨h.2.2.1, h.2.2.2.1, h.1, h.2.1, Ne.symm h.2.2.2.2⟩

/-- The ordered half of `WF`: a later node `n` touches neither the inputs nor the
output of an earlier node `m`. -/
abbrev Guards (m n : Node) : Prop :=
  n.out ≠ m.in1 ∧ n.out ≠ m.in2 ∧ n.out ≠ m.out

/-- Independence guards in both directions, so `Indep` nodes may run in either order
without breaking well-formedness. -/
theorem Indep.guards {m n : Node} (h : Indep m n) : Guards m n ∧ Guards n m :=
  ⟨⟨h.2.2.1, h.2.2.2.1, Ne.symm h.2.2.2.2⟩, ⟨h.1, h.2.1, h.2.2.2.2⟩⟩

/-- `WF` decomposed: per-node self-conditions plus pairwise guarding. -/
theorem wf_iff_pairwise :
    ∀ {p : List Node},
      WF p ↔ (∀ n ∈ p, n.out ≠ n.in1 ∧ n.out ≠ n.in2) ∧ p.Pairwise Guards := by
  intro p
  induction p with
  | nil =>
    constructor
    · intro _; exact ⟨fun n hn => (nomatch hn), List.Pairwise.nil⟩
    · intro _; exact WF.nil
  | cons n p ih =>
    constructor
    · intro h
      cases h with
      | cons hn1 hn2 hlater hp =>
        obtain ⟨hself, hpw⟩ := ih.mp hp
        refine ⟨?_, List.Pairwise.cons hlater hpw⟩
        intro m hm
        rcases List.mem_cons.mp hm with heq | hmem
        · subst heq; exact ⟨hn1, hn2⟩
        · exact hself m hmem
    · intro h
      obtain ⟨hself, hpw⟩ := h
      cases hpw with
      | cons hn hp =>
        have hs := hself n (List.mem_cons_self n p)
        exact WF.cons hs.1 hs.2 hn
          (ih.mpr ⟨fun m hm => hself m (List.mem_cons_of_mem n hm), hp⟩)

theorem Store.set_comm (σ : Store) {x y : String} (hxy : x ≠ y) (v w : Int) :
    (σ.set x v).set y w = (σ.set y w).set x v := by
  funext z
  unfold Store.set
  by_cases hzy : z = y
  · by_cases hzx : z = x
    · exact absurd (hzx ▸ hzy) hxy
    · simp [hzy, hzx, Ne.symm hxy]
  · by_cases hzx : z = x
    · simp [hzy, hzx, hxy]
    · simp [hzy, hzx]

/-- Independent steps commute. -/
theorem step_comm (σ : Store) {m n : Node} (h : Indep m n) :
    step (step σ m) n = step (step σ n) m := by
  obtain ⟨h1, h2, h3, h4, h5⟩ := h
  unfold step
  rw [Store.set_other σ _ (Ne.symm h1), Store.set_other σ _ (Ne.symm h2),
      Store.set_other σ _ (Ne.symm h3), Store.set_other σ _ (Ne.symm h4),
      Store.set_comm σ h5]

/-- A node independent of a whole list commutes across its evaluation. -/
theorem eval_step_comm {n : Node} :
    ∀ {p : List Node}, (∀ m ∈ p, Indep n m) → ∀ σ : Store,
      eval (step σ n) p = step (eval σ p) n := by
  intro p
  induction p with
  | nil => intro _ σ; rfl
  | cons m p ih =>
    intro h σ
    have hm : Indep n m := h m (List.mem_cons_self m p)
    have hp : ∀ m' ∈ p, Indep n m' := fun m' hm' => h m' (List.mem_cons_of_mem m hm')
    calc eval (step σ n) (m :: p)
        = eval (step (step σ n) m) p := rfl
      _ = eval (step (step σ m) n) p := by rw [step_comm σ hm]
      _ = step (eval (step σ m) p) n := ih hp (step σ m)
      _ = step (eval σ (m :: p)) n := rfl

/-- Permutations preserve `Pairwise` for symmetric relations. -/
theorem perm_pairwise {α : Type} {R : α → α → Prop} (hsymm : ∀ {a b : α}, R a b → R b a) :
    ∀ {p q : List α}, p.Perm q → p.Pairwise R → q.Pairwise R := by
  intro p q h
  induction h with
  | nil => exact id
  | cons x h ih =>
    intro hp
    cases hp with
    | cons hx hp =>
      exact List.Pairwise.cons (fun b hb => hx b (h.mem_iff.mpr hb)) (ih hp)
  | swap x y l =>
    intro hp
    cases hp with
    | cons hy hp =>
      cases hp with
      | cons hx hl =>
        refine List.Pairwise.cons (fun b hb => ?_)
          (List.Pairwise.cons (fun b hb => hy b (List.mem_cons_of_mem x hb)) hl)
        rcases List.mem_cons.mp hb with h1 | h2
        · subst h1; exact hsymm (hy x (List.mem_cons_self x l))
        · exact hx b h2
  | trans _ _ ih1 ih2 => exact fun hp => ih2 (ih1 hp)

/-- Evaluating a pairwise-independent list is invariant under permutation: workers in a
wave may commit in any order. -/
theorem eval_perm :
    ∀ {p q : List Node}, p.Perm q → p.Pairwise Indep → ∀ σ : Store, eval σ p = eval σ q := by
  intro p q h
  induction h with
  | nil => intro _ _; rfl
  | cons x h ih =>
    intro hp σ
    cases hp with
    | cons _ hp =>
      rw [eval_cons, eval_cons]
      exact ih hp (step σ x)
  | swap x y l =>
    intro hp σ
    cases hp with
    | cons hy _ =>
      have hyx : Indep y x := hy x (List.mem_cons_self x l)
      rw [eval_cons, eval_cons, eval_cons, eval_cons, step_comm σ hyx]
  | trans h1 _ ih1 ih2 =>
    intro hp σ
    rw [ih1 hp σ, ih2 (perm_pairwise (fun h => Indep.symm h) h1 hp) σ]

/-- Fork-join: two blocks touching pairwise-disjoint locations run in either order.
This is `par` with independent branches (single-writer discipline). -/
theorem eval_blocks_comm :
    ∀ {a : List Node} (b : List Node), (∀ m ∈ a, ∀ n ∈ b, Indep m n) →
      ∀ σ : Store, eval σ (a ++ b) = eval σ (b ++ a) := by
  intro a
  induction a with
  | nil => intro b _ σ; simp [eval_append]
  | cons m a ih =>
    intro b h σ
    have hm : ∀ n ∈ b, Indep m n := h m (List.mem_cons_self m a)
    have ha : ∀ m' ∈ a, ∀ n ∈ b, Indep m' n :=
      fun m' hm' => h m' (List.mem_cons_of_mem m hm')
    calc eval σ ((m :: a) ++ b)
        = eval (step σ m) (a ++ b) := rfl
      _ = eval (step σ m) (b ++ a) := ih b ha (step σ m)
      _ = eval (eval (step σ m) b) a := eval_append _ b a
      _ = eval (step (eval σ b) m) a := by rw [eval_step_comm hm σ]
      _ = eval (eval σ b) (m :: a) := rfl
      _ = eval σ (b ++ (m :: a)) := (eval_append σ b (m :: a)).symm

/-- A level-synchronous schedule: each executed wave is some permutation of the
corresponding canonical level. -/
inductive Waves : List (List Node) → List (List Node) → Prop
  | nil : Waves [] []
  | cons {l w : List Node} {ls ws : List (List Node)} :
      l.Perm w → Waves ls ws → Waves (l :: ls) (w :: ws)

/-- A wave schedule permutes the canonical program. -/
theorem waves_perm {ls ws : List (List Node)} (h : Waves ls ws) :
    ls.flatten.Perm ws.flatten := by
  induction h with
  | nil => exact List.Perm.refl _
  | cons hperm _ ih =>
    rw [List.flatten_cons, List.flatten_cons]
    exact hperm.append ih

theorem waves_pairwise_guards {ls ws : List (List Node)} (h : Waves ls ws) :
    (∀ l ∈ ls, l.Pairwise Indep) → ls.flatten.Pairwise Guards →
    ws.flatten.Pairwise Guards := by
  induction h with
  | nil => exact fun _ h => h
  | @cons l w ls ws hperm hws ih =>
    intro hind hpw
    rw [List.flatten_cons, List.pairwise_append] at hpw
    obtain ⟨_, hrest, hcross⟩ := hpw
    rw [List.flatten_cons, List.pairwise_append]
    refine ⟨?_, ih (fun l' hl' => hind l' (List.mem_cons_of_mem l hl')) hrest, ?_⟩
    · -- within a wave, Indep guards in both directions, whatever the commit order
      exact (perm_pairwise (fun h => Indep.symm h) hperm
        (hind l (List.mem_cons_self l ls))).imp fun hab => (Indep.guards hab).1
    · intro a ha b hb
      exact hcross a (hperm.mem_iff.mpr ha) b ((waves_perm hws).mem_iff.mpr hb)

/-- Well-formedness of the canonical order carries over to any wave order: within a
wave `Indep` supplies the guards both ways, across waves the canonical constraints
transfer through the permutations. -/
theorem waves_WF {ls ws : List (List Node)} (h : Waves ls ws)
    (hind : ∀ l ∈ ls, l.Pairwise Indep) (hwf : WF ls.flatten) : WF ws.flatten := by
  obtain ⟨hself, hpw⟩ := wf_iff_pairwise.mp hwf
  exact wf_iff_pairwise.mpr
    ⟨fun n hn => hself n ((waves_perm h).mem_iff.mpr hn),
     waves_pairwise_guards h hind hpw⟩

/-- Wave execution computes the same store as the canonical sequential order. -/
theorem eval_waves {ls ws : List (List Node)} (h : Waves ls ws)
    (hind : ∀ l ∈ ls, l.Pairwise Indep) :
    ∀ σ : Store, eval σ ls.flatten = eval σ ws.flatten := by
  induction h with
  | nil => intro _; rfl
  | @cons l w ls ws hperm _ ih =>
    intro σ
    rw [List.flatten_cons, List.flatten_cons, eval_append, eval_append,
        eval_perm hperm (hind l (List.mem_cons_self l ls)) σ]
    exact ih (fun l' hl' => hind l' (List.mem_cons_of_mem l hl')) _

/-- Parallel propagation correctness: propagating in *any* level-synchronous wave order
from a consistent old run computes the from-scratch result of the canonical program.
Well-formedness is required only of the canonical order — `waves_WF` transports it to
whatever order the workers actually committed. -/
theorem propagate_waves_correct {ls ws : List (List Node)}
    (h : Waves ls ws) (hind : ∀ l ∈ ls, l.Pairwise Indep)
    (hwf : WF ls.flatten) (σ₀ σ₁ : Store) :
    propagate (eval σ₀ ls.flatten) σ₁ ws.flatten = eval σ₁ ls.flatten := by
  rw [eval_waves h hind σ₀, propagate_correct (waves_WF h hind hwf) σ₀ σ₁,
      ← eval_waves h hind σ₁]

end PsacModel
