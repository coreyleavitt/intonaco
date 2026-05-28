/-
  intonaco#56 — mechanized proof of the consistency model (Lean 4).

  HONEST POSITIONING (see the literature search recorded with this issue):
  the glitch-freedom THEOREM is established — paper-proven for runtime FRP
  (FrTime, REScala) and machine-checked for synchronous dataflow (Vélus, in
  Coq). The contribution here is the SYNTHESIS: a machine-checked glitch-free +
  confluent scheduling proof for a COMPILE-TIME-scheduled, HYBRID static/dynamic
  tier reactive substrate — a point neither the FRP nor the synchronous-language
  communities occupy. Lemma B (cross-tier monotonicity) is the genuinely-new
  core; Lemmas 1/2 are re-mechanized, cited as known.

  This file is checked by the `intonaco-proof` Lean image, NOT the Nim suite.
-/

namespace Intonaco

-- The `if hmem :` guard in `oracle` is used by `decreasing_by`, not its body;
-- the linter can't see that, so silence its false "unused" report.
set_option linter.unusedVariables false

/-- A node is scheduled either at compile time (its height baked, possibly an
    over-approximation across all branches) or at runtime (height accumulated
    as exactly `1 + max` of the deps actually read). -/
inductive Tier where
  | static
  | dynamic
deriving DecidableEq

/-- `max` of `(dep height + 1)` over the deps — the height-assignment rule both
    tiers follow, matching the implementation's `composeHeight`: an empty dep
    list gives `0` (a source/constant is height 0); a non-empty one gives
    `1 + max(dep heights)`. The static tier may baked-over-approximate (`≥`). -/
def maxSucc {α : Type} (h : α → Nat) : List α → Nat
  | [] => 0
  | x :: xs => max (h x + 1) (maxSucc h xs)

/-- The reactive dependency graph with a height assignment. The two assignment
    laws are exactly what the substrate maintains: dynamic nodes accumulate
    `1 + max(deps)`; static nodes bake a height that is `≥ 1 + max(deps)` (the
    over-approximation across non-taken branches — intonaco#53's `fixedHeight`). -/
structure RGraph where
  Node    : Type
  nodeDec : DecidableEq Node            -- nodes have identity (membership is decidable)
  Value   : Type
  dflt    : Value                       -- the pre-evaluation placeholder
  deps    : Node → List Node
  h       : Node → Nat
  tier    : Node → Tier
  /-- a node's computation: a function of the *store* (all node values). -/
  f       : Node → (Node → Value) → Value
  /-- LOCALITY: `f v` reads only its declared deps — it agrees on any two
      stores that agree on `deps v`. This is what makes "observing a transient"
      expressible (and what the read-set extraction guarantees). -/
  flocal  : ∀ v s1 s2, (∀ u, u ∈ deps v → s1 u = s2 u) → f v s1 = f v s2
  dynLaw  : ∀ v, tier v = Tier.dynamic → h v = maxSucc h (deps v)
  statLaw : ∀ v, tier v = Tier.static  → h v ≥ maxSucc h (deps v)

attribute [instance] RGraph.nodeDec   -- so `u ∈ g.deps v` is decidable

/-- Every dependency's height, plus one, is ≤ the `maxSucc` of the dep list
    (i.e. every dep is strictly below it). -/
theorem memSuccLe {α : Type} (h : α → Nat) :
    ∀ (l : List α) (u : α), u ∈ l → h u + 1 ≤ maxSucc h l := by
  intro l
  induction l with
  | nil => intro u hu; simp at hu
  | cons x xs ih =>
    intro u hu
    rcases List.mem_cons.mp hu with rfl | hmem
    · exact Nat.le_max_left _ _
    · exact Nat.le_trans (ih u hmem) (Nat.le_max_right _ _)

/- ===================================================================== -/
/- intonaco#62 — DERIVING `statLaw` from the classifier's two obligations. -/
/- `statLaw` is currently an asserted field of `RGraph`. The substrate     -/
/- actually MAINTAINS it: the compile-time classifier (a) OVER-collects     -/
/- the read-set (the baked dep set `D` is a superset of what the body       -/
/- reads) and (b) bakes `1 + maxSucc heightOf D` with each collected dep's  -/
/- height itself sound. The two `maxSucc` monotonicity lemmas below reduce   -/
/- `statLaw` to exactly those two preconditions.                            -/

/-- **`maxSucc` monotone in the dependency list (subset).** If every element of
    `l₁` also occurs in `l₂`, then `maxSucc h l₁ ≤ maxSucc h l₂`. A dropped or
    permuted dep can only lower the max. Built on `memSuccLe`. -/
theorem maxSucc_mono_subset {α : Type} (h : α → Nat) :
    ∀ (l₁ l₂ : List α), (∀ x, x ∈ l₁ → x ∈ l₂) → maxSucc h l₁ ≤ maxSucc h l₂ := by
  intro l₁
  induction l₁ with
  | nil => intro l₂ _; exact Nat.zero_le _
  | cons x xs ih =>
    intro l₂ hsub
    -- `maxSucc h (x :: xs) = max (h x + 1) (maxSucc h xs)`; bound both sides.
    apply Nat.max_le.mpr
    refine ⟨?_, ?_⟩
    · exact memSuccLe h l₂ x (hsub x (List.mem_cons.mpr (Or.inl rfl)))
    · exact ih l₂ (fun y hy => hsub y (List.mem_cons.mpr (Or.inr hy)))

/-- **`maxSucc` pointwise monotone in the height function.** If `h₁ x ≤ h₂ x`
    for every element of the list, then `maxSucc h₁ l ≤ maxSucc h₂ l`. The bound
    is required only on `l`'s elements because `maxSucc … l` depends on nothing
    else — that membership-aware form is what `overApproxSound` needs. A short
    list induction. -/
theorem maxSucc_mono_height {α : Type} (h₁ h₂ : α → Nat) :
    ∀ (l : List α), (∀ x, x ∈ l → h₁ x ≤ h₂ x) → maxSucc h₁ l ≤ maxSucc h₂ l := by
  intro l
  induction l with
  | nil => intro _; exact Nat.le_refl _
  | cons x xs ih =>
    intro hle
    simp only [maxSucc]
    have hx : h₁ x + 1 ≤ h₂ x + 1 :=
      Nat.succ_le_succ (hle x (List.mem_cons.mpr (Or.inl rfl)))
    have hxs : maxSucc h₁ xs ≤ maxSucc h₂ xs :=
      ih (fun y hy => hle y (List.mem_cons.mpr (Or.inr hy)))
    apply Nat.max_le.mpr
    exact ⟨Nat.le_trans hx (Nat.le_max_left _ _),
           Nat.le_trans hxs (Nat.le_max_right _ _)⟩

/-- **Over-approximation soundness (intonaco#62, the headline).** The compile-time
    classifier may bake the *static* height from an OVER-collected dependency set
    `D` (`readset ⊆ D` — every dep actually read is captured, plus possibly more
    from non-taken branches) using collected heights `heightOf` that themselves
    over-approximate the true heights (`heightOf d ≥ trueHeight d`). Then the
    baked height `1 + maxSucc heightOf D` dominates the EXACT height
    `maxSucc trueHeight readset` that a dynamic re-evaluation would assign — i.e.
    the over-approximation property (`statLaw`'s `≥`) holds *by construction*.

    This reduces the asserted `statLaw` field to two clearly-named obligations
    the classifier discharges: the walk over-collects, and dep heights are sound.

    `D` and `readset` range over an arbitrary node type `Node`; `heightOf` and
    `trueHeight` are arbitrary height assignments. -/
theorem overApproxSound {Node : Type}
    (heightOf trueHeight : Node → Nat) (D readset : List Node)
    (hCover : ∀ x, x ∈ readset → x ∈ D)               -- walk OVER-collects
    (hSound : ∀ d, d ∈ D → trueHeight d ≤ heightOf d)  -- collected heights sound
    : maxSucc trueHeight readset ≤ 1 + maxSucc heightOf D := by
  -- shrink the dep list (readset ⊆ D) under the TRUE heights …
  have hsubset : maxSucc trueHeight readset ≤ maxSucc trueHeight D :=
    maxSucc_mono_subset trueHeight readset D hCover
  -- … then lift the height function pointwise (true ≤ collected) on `D`.
  have hheight : maxSucc trueHeight D ≤ maxSucc heightOf D :=
    maxSucc_mono_height trueHeight heightOf D hSound
  -- chain, then `maxSucc heightOf D ≤ 1 + maxSucc heightOf D` closes the gap.
  omega

/-- **Composition corollary for the linear collection operators.** The
    `derive`/`keep`/`fold` operators (intonaco's collection algebra) are
    single-source and bake `sourceHeight + 1`. Modelled in the abstract node
    graph, such an operator node `v` has a singleton dep list `[src]` and baked
    height `g.h src + 1`. Then the over-approximation property holds *exactly*
    (with equality, not just `≥`): there is no slack to verify, because a linear
    single-source operator collects precisely its one source.

    This is the faithful statement against the existing abstract model:
    `maxSucc g.h [src] = max (g.h src + 1) 0 = g.h src + 1`, which is the baked
    height verbatim. A larger operator model (separate `Op` syntax, an evaluator
    relating operator output to source values) would be needed to *also* prove
    the operators preserve glitch-freedom of their stream contents; that is out
    of scope here — this corollary only discharges the HEIGHT obligation
    (`statLaw`) that #62 is about, which is all the scheduler proof consumes. -/
theorem linearOpStatLaw (g : RGraph) (v src : g.Node)
    (hdeps : g.deps v = [src]) (hbaked : g.h v = g.h src + 1) :
    g.h v ≥ maxSucc g.h (g.deps v) := by
  rw [hdeps, hbaked]
  simp only [maxSucc]   -- maxSucc g.h [src] = max (g.h src + 1) 0
  omega

/-- **Lemma B (cross-tier height monotonicity).** For every edge `u → v`
    (i.e. `u ∈ deps v`), `h u < h v` — regardless of which tiers `u` and `v`
    are in. This is what makes the height order a topological order across the
    static/dynamic seam, on which Lemmas 1 and 2 rest. -/
theorem lemmaB (g : RGraph) (v u : g.Node) (hu : u ∈ g.deps v) :
    g.h u < g.h v := by
  have hlt : g.h u + 1 ≤ maxSucc g.h (g.deps v) := memSuccLe g.h (g.deps v) u hu
  cases htier : g.tier v with
  | static  => have hs := g.statLaw v htier; omega
  | dynamic => have hd := g.dynLaw v htier; omega

/-- **The atomic oracle `A`.** The ideal settled store: each node's value is
    `f` of its dependencies' settled values. Defined by well-founded recursion
    on height — terminating because every dependency has strictly lower height
    (Lemma B). The recursive call is guarded by `u ∈ deps v`, so off-deps reads
    fall to `dflt` (locality makes that irrelevant). -/
def oracle (g : RGraph) (v : g.Node) : g.Value :=
  g.f v (fun u => if hmem : u ∈ g.deps v then oracle g u else g.dflt)
termination_by g.h v
decreasing_by exact lemmaB g v u hmem

/-- **The fixpoint property of the oracle:** `A v = f v A`. Follows from
    locality — the guarded store agrees with `oracle g` on `deps v`. -/
theorem oracleFixpoint (g : RGraph) (v : g.Node) :
    oracle g v = g.f v (oracle g) := by
  rw [oracle]
  apply g.flocal
  intro u hu
  simp [hu]

/-- Update one node's value in the store. -/
def upd (g : RGraph) (s : g.Node → g.Value) (v : g.Node) (val : g.Value) :
    g.Node → g.Value :=
  fun u => if u = v then val else s u

/-- **The height-ordered drain `H`.** Process each node in `order`, writing
    `f node (current store)`. This is the REAL stateful scheduler: it COULD
    observe a transient if `order` mis-ordered a dependency. The theorems show a
    topologically-valid order (which a height-sorted order is, via Lemma B)
    never does. -/
def drain (g : RGraph) : List g.Node → (g.Node → g.Value) → (g.Node → g.Value)
  | [], s => s
  | v :: rest, s => drain g rest (upd g s v (g.f v s))

/-- `order` is topologically valid against an already-processed set `P`: every
    node's dependencies are processed before it. A height-sorted order is such
    an order — that bridge (via Lemma B) is the height-specific part (slice 5). -/
def TopoValid (g : RGraph) (P : g.Node → Prop) : List g.Node → Prop
  | [] => True
  | v :: rest => (∀ u, u ∈ g.deps v → P u) ∧ TopoValid g (fun w => w = v ∨ P w) rest

/-- The drain's core invariant: from a processed set `P` whose nodes already
    hold their oracle values, processing a topologically-valid `order` leaves
    every node (in `P` or `order`) holding its oracle value. -/
theorem drainCorrect (g : RGraph) :
    ∀ (order : List g.Node) (P : g.Node → Prop) (s : g.Node → g.Value),
      TopoValid g P order →
      (∀ w, P w → s w = oracle g w) →
      ∀ w, (P w ∨ w ∈ order) → drain g order s w = oracle g w := by
  intro order
  induction order with
  | nil =>
    intro P s _ hPs w hw
    simp only [drain]
    rcases hw with hP | hmem
    · exact hPs w hP
    · simp at hmem
  | cons v rest ih =>
    intro P s htv hPs w hw
    obtain ⟨hdeps, htvrest⟩ := htv
    simp only [drain]
    -- f v s = oracle v, because s agrees with the oracle on deps v (deps ⊆ P)
    have hfv : g.f v s = oracle g v := by
      rw [oracleFixpoint]
      apply g.flocal
      intro u hu
      exact hPs u (hdeps u hu)
    -- the updated store agrees with the oracle on `insert v P`
    have hPs' : ∀ w, (w = v ∨ P w) → upd g s v (g.f v s) w = oracle g w := by
      intro w hw'
      simp only [upd]
      by_cases hwv : w = v
      · subst hwv; rw [if_pos rfl]; exact hfv
      · rw [if_neg hwv]
        rcases hw' with rfl | hPw
        · exact absurd rfl hwv
        · exact hPs w hPw
    -- the remaining drain, by induction
    have hrec := ih (fun w => w = v ∨ P w) (upd g s v (g.f v s)) htvrest hPs' w
    rcases hw with hP | hmem
    · exact hrec (Or.inl (Or.inr hP))
    · rcases List.mem_cons.mp hmem with rfl | hmem'
      · exact hrec (Or.inl (Or.inl rfl))
      · exact hrec (Or.inr hmem')

/-- **Lemma 1 (confluence).** A topologically-valid, complete drain from the
    initial store reaches the oracle store `A` exactly. -/
theorem confluence (g : RGraph) (order : List g.Node)
    (htv : TopoValid g (fun _ => False) order) (hcomplete : ∀ w, w ∈ order) :
    ∀ w, drain g order (fun _ => g.dflt) w = oracle g w := by
  intro w
  exact drainCorrect g order (fun _ => False) (fun _ => g.dflt) htv
    (fun _ h => absurd h id) w (Or.inr (hcomplete w))

/-- **Lemma 2 (observational glitch-freedom).** When the drain reaches node `v`
    (the head of the remaining order) with the already-processed set `P` holding
    final values, every dependency of `v` already holds its ORACLE (final)
    value — the read observes no transient. `drainCorrect` maintains the `P`
    invariant at every step, so this holds throughout the drain. -/
theorem glitchFree (g : RGraph) (P : g.Node → Prop) (v : g.Node)
    (rest : List g.Node) (s : g.Node → g.Value)
    (htv : TopoValid g P (v :: rest)) (hPs : ∀ w, P w → s w = oracle g w) :
    ∀ u, u ∈ g.deps v → s u = oracle g u := by
  obtain ⟨hdeps, _⟩ := htv
  intro u hu
  exact hPs u (hdeps u hu)

/-- `order` is in nondecreasing height order — what the worklist scheduler
    produces (it drains minimum-height-first). -/
def Sorted (g : RGraph) : List g.Node → Prop
  | [] => True
  | v :: rest => (∀ w, w ∈ rest → g.h v ≤ g.h w) ∧ Sorted g rest

/-- **The bridge (this is where Lemma B does its work).** A height-sorted,
    complete order is topologically valid: every dependency, having strictly
    lower height (Lemma B), cannot sit at-or-after its dependent in a sorted
    order, so it has already been processed. This connects the height-ordered
    scheduler to the topological-order correctness of `confluence`/`glitchFree`. -/
theorem sortedTopoValid (g : RGraph) :
    ∀ (order : List g.Node) (P : g.Node → Prop),
      Sorted g order →
      (∀ w, P w ∨ w ∈ order) →            -- every node is processed or remaining
      TopoValid g P order := by
  intro order
  induction order with
  | nil => intro P _ _; trivial
  | cons v rest ih =>
    intro P hsorted hcomplete
    obtain ⟨hvmin, hsrest⟩ := hsorted
    refine ⟨?_, ?_⟩
    · -- deps v ⊆ P
      intro u hu
      have hlt : g.h u < g.h v := lemmaB g v u hu
      rcases hcomplete u with hPu | hmem
      · exact hPu
      · rcases List.mem_cons.mp hmem with rfl | hmemrest
        · exact absurd hlt (Nat.lt_irrefl _)           -- u = v: h v < h v
        · have hge : g.h v ≤ g.h u := hvmin u hmemrest  -- u after v: h v ≤ h u
          omega
    · -- the remaining order stays valid against the grown processed set
      refine ih (fun w => w = v ∨ P w) hsrest ?_
      intro w
      rcases hcomplete w with hPw | hmem
      · exact Or.inl (Or.inr hPw)
      · rcases List.mem_cons.mp hmem with rfl | hmemrest
        · exact Or.inl (Or.inl rfl)
        · exact Or.inr hmemrest

/-- **Main theorem.** The HEIGHT-ORDERED drain over a sorted, complete order
    reaches the oracle store `A` exactly — the compile-time-scheduled hybrid-tier
    scheduler is confluent and (with `glitchFree`) glitch-free, with the height
    order justified by cross-tier monotonicity (Lemma B) through the bridge. -/
theorem heightOrderedCorrect (g : RGraph) (order : List g.Node)
    (hsorted : Sorted g order) (hcomplete : ∀ w, w ∈ order) :
    ∀ w, drain g order (fun _ => g.dflt) w = oracle g w := by
  have htv : TopoValid g (fun _ => False) order :=
    sortedTopoValid g order (fun _ => False) hsorted (fun w => Or.inr (hcomplete w))
  exact confluence g order htv hcomplete

/- ===================================================================== -/
/- SLICE 6 (A): the ACTUAL min-height worklist, not an idealized order.   -/
/- The #48 scheduler drains minimum-height-first. We model exactly that — -/
/- repeated extract-min over the dirty set — and prove it reaches the      -/
/- oracle. The crux: the minimum-height dirty node has NO dirty dependency -/
/- (deps are strictly lower height by Lemma B, but it is the minimum), so  -/
/- every dep is already final. No pre-sorting assumed.                     -/

/-- The minimum-height node among `best` and `l` — the worklist's extract-min. -/
def argMin (g : RGraph) (best : g.Node) : List g.Node → g.Node
  | [] => best
  | x :: xs => argMin g (if g.h x < g.h best then x else best) xs

theorem argMin_mem (g : RGraph) :
    ∀ (l : List g.Node) (best : g.Node),
      argMin g best l = best ∨ argMin g best l ∈ l := by
  intro l
  induction l with
  | nil => intro best; left; rfl
  | cons x xs ih =>
    intro best
    simp only [argMin]
    by_cases hx : g.h x < g.h best
    · rw [if_pos hx]
      rcases ih x with h1 | h2
      · right; rw [h1]; exact List.mem_cons.mpr (Or.inl rfl)
      · right; exact List.mem_cons.mpr (Or.inr h2)
    · rw [if_neg hx]
      rcases ih best with h1 | h2
      · left; exact h1
      · right; exact List.mem_cons.mpr (Or.inr h2)

theorem argMin_le_best (g : RGraph) :
    ∀ (l : List g.Node) (best : g.Node), g.h (argMin g best l) ≤ g.h best := by
  intro l
  induction l with
  | nil => intro best; simp only [argMin]; exact Nat.le_refl _
  | cons x xs ih =>
    intro best
    simp only [argMin]
    by_cases hx : g.h x < g.h best
    · rw [if_pos hx]; exact Nat.le_trans (ih x) (Nat.le_of_lt hx)
    · rw [if_neg hx]; exact ih best

theorem argMin_le (g : RGraph) :
    ∀ (l : List g.Node) (best u : g.Node),
      u ∈ l → g.h (argMin g best l) ≤ g.h u := by
  intro l
  induction l with
  | nil => intro best u hu; simp at hu
  | cons x xs ih =>
    intro best u hu
    simp only [argMin]
    rcases List.mem_cons.mp hu with rfl | hmem
    · by_cases hx : g.h u < g.h best
      · rw [if_pos hx]; exact argMin_le_best g xs u
      · rw [if_neg hx]
        exact Nat.le_trans (argMin_le_best g xs best) (Nat.le_of_not_lt hx)
    · by_cases hx : g.h x < g.h best
      · rw [if_pos hx]; exact ih x u hmem
      · rw [if_neg hx]; exact ih best u hmem

/-- The worklist drain: repeatedly extract the minimum-height node and process
    it. Terminates because `erase` shrinks the list. -/
def worklist (g : RGraph) : List g.Node → (g.Node → g.Value) → (g.Node → g.Value)
  | [], s => s
  | v :: rest, s =>
      let m := argMin g v rest
      worklist g ((v :: rest).erase m) (upd g s m (g.f m s))
  termination_by l => l.length
  decreasing_by
    have hm : argMin g v rest ∈ v :: rest := by
      rcases argMin_mem g rest v with h | h
      · rw [h]; exact List.mem_cons.mpr (Or.inl rfl)
      · exact List.mem_cons.mpr (Or.inr h)
    have hlen : ((v :: rest).erase (argMin g v rest)).length = (v :: rest).length - 1 :=
      List.length_erase_of_mem hm
    rw [hlen]
    simp only [List.length_cons]
    omega

/-- **Lemma 1′ (worklist confluence).** From a store agreeing with the oracle on
    every NON-dirty node, the min-height worklist over `dirty` reaches the oracle
    everywhere. The min-height node's deps are all already-final, so each
    extract-min reads only final values. -/
theorem worklistCorrect (g : RGraph) :
    ∀ (dirty : List g.Node) (s : g.Node → g.Value),
      (∀ w, w ∉ dirty → s w = oracle g w) →
      ∀ w, worklist g dirty s w = oracle g w := by
  intro dirty s
  induction dirty, s using worklist.induct g with
  | case1 s => -- dirty = []
    intro hs w; simp only [worklist]; exact hs w (by simp)
  | case2 v rest s m ih =>   -- `m := argMin g v rest` (a let-binder in the principle)
    intro hs w
    simp only [worklist]
    refine ih ?_ w
    intro w' hw'
    -- `m` is in (v::rest) with minimal height (using m ≡ argMin g v rest, defeq)
    have hm : m ∈ v :: rest := by
      rcases argMin_mem g rest v with h | h
      · exact List.mem_cons.mpr (Or.inl h)
      · exact List.mem_cons.mpr (Or.inr h)
    have hmin : ∀ u, u ∈ v :: rest → g.h m ≤ g.h u := by
      intro u hu
      rcases List.mem_cons.mp hu with rfl | hmem
      · exact argMin_le_best g rest u
      · exact argMin_le g rest v u hmem
    -- every dep of the min is NON-dirty (a dirty dep would be below the minimum)
    have hdepfinal : ∀ u, u ∈ g.deps m → s u = oracle g u := by
      intro u hu
      have hlt : g.h u < g.h m := lemmaB g m u hu
      apply hs
      intro hud
      exact absurd (hmin u hud) (by omega)
    have hfm : g.f m s = oracle g m := by
      rw [oracleFixpoint]
      exact g.flocal m s (oracle g) hdepfinal
    -- the updated store agrees with the oracle on every non-(erased) node
    simp only [upd]
    by_cases hw'm : w' = m
    · rw [if_pos hw'm, hw'm]; exact hfm
    · rw [if_neg hw'm]
      apply hs
      intro hw'd
      exact hw' ((List.mem_erase_of_ne hw'm).mpr hw'd)

-- Attestation: the proofs are axiom-clean (no `sorryAx`).
#print axioms maxSucc_mono_subset
#print axioms maxSucc_mono_height
#print axioms overApproxSound
#print axioms linearOpStatLaw
#print axioms lemmaB
#print axioms oracleFixpoint
#print axioms confluence
#print axioms glitchFree
#print axioms heightOrderedCorrect
#print axioms worklistCorrect

end Intonaco
