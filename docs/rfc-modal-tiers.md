# Modal compile-time scheduling for reactive substrates

**Status**: Proposed (2026-05-28)
**Author**: Corey Leavitt
**Companion to**: `fresco/docs/rfc-consistency-model.md` (the lead direction; consistency is the foundational modality), `fresco/docs/roadmap-compile-time-research.md`, `intonaco/docs/rfc-c-shape-migration.md` (the substrate this RFC formalizes)
**Tracking issue**: coreyleavitt/intonaco#89

## TL;DR

intonaco's split between `Signal[T]` (static tier) and `Dynamic[T]` (dynamic tier) is **secretly a modal type system** — every binding lives in a modality, and the walker enforces cross-modality reads as forbidden. The current naming hides the underlying type theory. This RFC makes the modality explicit, registers `Signal[T] ≡ □T` (necessity) and `Dynamic[T] ≡ ◇T` (possibility) as judgmental modalities, and reframes the substrate as **modality-polymorphic**. The framing unlocks a principled extension story: each future research direction (transactions, refinement, substructural, guarded productivity) lands as an additional modality with its own walker contract, sharing the platform from M-α.

## The gap

I am not aware of a reactive substrate that formalizes its static/dynamic split as a modal system. Most substrate authors describe it informally as "the static fragment vs the dynamic fallback" — e.g., Solid.js's `createMemo` vs `untrack`; Signals-rs's `compute` vs `effect_with_deps`; Sigils's `signal` vs `signalAsync`; Vue's reactive vs effect. In each, the boundary between "we know your deps at compile time" and "we figure them out at runtime" is a runtime convention — a check, a flag, a missing optimization, or simply a behavioral asymmetry. None lifts the split to the type system as a modality, and none uses the modality to drive scheduling soundness.

This is a non-trivial gap. Modal type theory has decades of structural-rule machinery for stratifying "definitely known" from "possibly resolved" — necessity (`□`) and possibility (`◇`) modalities, lift and descent operators, soundness theorems for cross-modality coercion. Reactive substrates have been re-inventing pieces of this informally and incompletely. Lifting the framing into a substrate's type system is a contribution **in the substrate setting** even though the type theory itself is mature.

## The depth

### Modal interpretation of intonaco's two tiers

The judgmental modal logic of Davies and Pfenning (POPL 2001, "A Modal Analysis of Staged Computation") provides the structural backbone. The relevant fragment:

- A modality `□A` is read "necessarily-A," meaning the inhabitant of `□A` is known at compile time and can be used at any later stage.
- A modality `◇A` is read "possibly-A," meaning the inhabitant is resolved at runtime.
- **Lift** `□A → ◇A` is universally safe: a compile-time-known value can be supplied where a runtime-resolved one is expected.
- **Descent** `◇A → □A` is *forbidden* without an explicit operator: you cannot recover compile-time information that was not present.
- Necessity introduction requires a *modally-pure* context — the body of a `□A` constructor may only reference variables already known at compile time. This is the structural rule that propagates the modality cleanly.

intonaco's substrate already enforces this structure, expressed in different vocabulary:

| Modal theory | intonaco substrate |
|---|---|
| `□T` (necessity) | `Signal[T]` |
| `◇T` (possibility) | `Dynamic[T]` |
| Modal purity in `□`-context | The walker's "no reactive read outside `[deps]`" + "no `Dynamic[_]` typed sym in a `computed`/`effect` body" |
| Lift `□T → ◇T` | Implicit; a `Signal[T]` is silently usable where a `Dynamic[T]` is expected |
| Descent `◇T → □T` | *Forbidden* — the walker rejects `Dynamic[_]` reads in static-tier bodies |
| `□`-introduction (compile-time-resolved binding) | `computed name, [deps]: body` (height baked, walker fires) |
| `◇`-introduction (runtime-resolved binding) | `dynamic name: body` (no height, runtime-tracked) |

The walker IS the modality's introduction/elimination check. The `{.height: N.}` pragma IS the necessity-context's stage marker. The Lean proof (`Consistency.lean`'s `overApproxSound`) is the soundness theorem for the necessity-tier scheduling: under the structural rule that `□`-bodies read only their declared deps (enforced by construction in the C-shape), the over-approximation of read-sets is sound, and the height-ordered worklist is glitch-free.

### What the framing *adds* (the genuine contribution)

The substrate works today without naming any of this. What the modal framing adds:

**1. A principled extension slot for additional modalities.**

Each future research direction reduces to "add a modality `*T` with its own walker contract":

- **Transactions (#45)**: `⊠T` — *transactional*. Bindings in this modality must commit atomically or rebut; descent into static is forbidden (no compile-time rollback) but lift from static to transactional is safe (a compile-time-known value is trivially committable). Walker contract: every read within `⊠T` is within a transaction scope; no escape via opaque callee.
- **Refinement (#4)**: `□{v | P(v)} T` — *refined necessity*. A necessity modality parameterized by a predicate; the discharge is at write sites. This is a known shape in modal logic (Trifonov / Tofte style refined types lift cleanly to a modality). Walker contract: each write site within the modality discharges its predicate.
- **Substructural under re-execution (#3)**: a *linear-bounded* modality `!ⁿT` — *consumable at most n times*. Re-execution semantics determine whether bound is per-execution (`!T`-classical) or per-lifetime (a genuinely new shape). Walker contract: consumption multiset bounded.
- **Guarded productivity (#46)**: `▷T` — *next-step possibility*. The guard operator marks one-step deferral; productive cyclic structures pass through `▷T` on each turn. Walker contract: every cyclic SCC passes through `▷T`.

The modality model gives each direction a **shared structural template** instead of needing each to invent its own walker check from scratch. The M-α platform (issue #79-83) is what makes this concrete: each direction registers a walker pass keyed to its modality.

**2. A unified statement of cross-tier soundness.**

The Lean proof currently proves `overApproxSound` for the static tier and informally argues the dynamic tier is sound by construction (runtime tracking captures the exact read-set). Under the modal framing, both are instances of one theorem: *for any modality `*`, an introduction of `*T` admits no read outside the declared `*`-context*. The static tier is the `□` instance; the dynamic tier is the `◇` instance. Future modalities reuse the proof skeleton; only the modality-specific predicate changes.

**3. A principled cross-modality coercion API.**

Lift `□T → ◇T` is currently implicit. Under the modal framing, it becomes an explicit (no-op) coercion `liftDynamic[T](s: Signal[T]): Dynamic[T]`. The current implicit conversion still works; the explicit form is documentation and a place to attach future cross-modality typing checks (e.g., a refined-necessity-to-possibility lift may need to weaken the refinement). Descent `◇T → □T` remains forbidden — no `freeze` operator — because you cannot recover compile-time information that wasn't there.

**4. Compositional reasoning about multi-modal bindings.**

A binding may be in multiple modalities simultaneously: e.g., a `computed display, [count]:` that reads a refined-bounded `Signal[Nat]` is in `□ ∧ □{n | n ≥ 0}`. The modal product captures the joint constraint; the walker discharges both. Under the current ad-hoc framing, each pair of directions has to specify how it composes; under modal framing, composition is structural.

## Nim leverage

- **Typed macros** (already shipped): the walker is a typed-macro pass; modal checks land as additional registered passes via M-α.2. No new Nim feature needed.
- **Concepts**: modality-polymorphic operators (M-δ's `derive`/`keep`/`fold` dispatching on input modality) use Nim's concepts to encode "this T inhabits one of the modalities the operator supports." Cleaner than explicit branching at the type-class level.
- **`distinct T`** (already used for `Signal[T]` / `Dynamic[T]`): each new modality is a `distinct T`-style type; the walker keys checks off the type-shape.
- **Custom pragmas** (already used: `{.height.}`): each modality may bake its own pragma (`{.refinement.}`, `{.linearity.}`, `{.guard.}`); composition is pragma-set composition.
- **`std/macrocache`**: for memoizing modality-discharge results across compilation units. Cheap to add when needed.
- **The pass-registry (M-α.2)**: directly inherits the modal framing. Each modality registers a pass; the pass-registry IS the modal-check substrate.

## Surface (sketch)

```nim
# After M-α + this RFC + initial transactional direction work:

signals:
  count = 0                   # □Int (necessity, baked height 0)

computed display, [count]:    # □String, baked height 1 — pure necessity introduction
  "Count: " & $count

dynamic now: time.Now          # ◇Time — possibility introduction; no height
                                # the type ◇Time = Dynamic[Time] is the modality marker

# Modality coercion (explicit form; the implicit form still works for ergonomics):
let displayDyn: Dynamic[string] = liftDynamic(display)    # □String → ◇String, safe

# Forbidden — the walker catches it at compile time:
# computed bad, [display, now]:    # Mixed modality with a ◇ dep is rejected;
#   display & " " & now             # a static binding can't have a ◇ in [deps]

# Future-direction extension example (transactional modality):
transactional cart, [items]:        # ⊠CartState — atomic-or-rebut
  CartState(total: sum(items.map(price)))

# Future-direction extension example (refined necessity):
computed pct, [count, total: Refined[Int, lo=1]]:    # □ ∧ □{n | n ≥ 1}
  count * 100 div total            # divide-by-zero impossible by the refinement
```

## Relationship to other directions

| Direction | Modality | Status under this RFC |
|---|---|---|
| **1. Consistency model** (lead) | `□` (necessity) and `◇` (possibility); the cross-modality monotonicity is its soundness theorem | The Lean proof's `overApproxSound` is the necessity-modality's introduction-rule soundness |
| **2. Transactions** (#45) | `⊠` (transactional necessity) | This RFC unblocks #45 by giving it a modality slot instead of a parallel substrate |
| **3. Substructural under re-execution** (#3) | `!ⁿ` (n-bounded linear) | The re-execution open question becomes "is the modality per-execution or per-lifetime?" — a modal question |
| **4. Refinement types** (#4) | `□{v | P(v)}` (refined necessity) | The refinement is a parameterization of the necessity modality, not a new tier |
| **5. Guarded productivity** (#46) | `▷` (next-step possibility) | The guard operator marks the modality's introduction |

This RFC does NOT replace any direction. It provides a shared vocabulary that each direction's RFC can adopt to clarify its contract.

## Research artifact

**Paper outline**: "Modal compile-time scheduling for reactive substrates."

- §1: The gap. Survey of how mainstream substrates (Solid, Signals, MobX, Sigils, Vue) handle the static/dynamic split informally.
- §2: A modal model. Davies-Pfenning judgmental modality applied to reactive scheduling; necessity for compile-time-known graphs, possibility for runtime-resolved.
- §3: The substrate's structural enforcement. The walker as modality check; the height carrier as necessity-stage marker.
- §4: Soundness, mechanized. The Lean proof reframed as a per-modality theorem; the `overApproxSound` becomes the `□`-soundness instance.
- §5: Extension to other modalities. Transactions / refinement / substructural / guarded as additional modality slots; sketches of the walker contracts.
- §6: Engineering primitives. The intonaco substrate as the worked example; the macro layer, the pass-registry (M-α.2), the substrate kit (M-α.3).
- §7: Related work. Modal type theory; staged computation; FRP type systems (Wan-Hudak, Cooper-Krishnamurthi); incremental computation models (Acar's self-adjusting computation, Adapton).
- §8: Limitations and future. Multi-modal composition; soundness for descent operators (when, if ever, principled?).

**Venue candidates**: ICFP, POPL workshop (PLMW, TyDe), PLDI Substrate (a fictional ideal venue), substrate-design workshops (PLDI's substrate panels). The contribution is *applied modal type theory in a programming substrate*, not novel modal theory per se. Programming-language venues with a "real-world model" angle are the fit.

**Blog post**: a shorter framing for the substrate-design community ("Why your reactive substrate is secretly modal and what to do about it"). Higher impact than a paper for the substrate-author audience; should ship first.

## Estimated effort

- **RFC**: this document — done.
- **Cross-references** to per-direction RFCs (one paragraph each, identifying each direction's modality): ~1 session.
- **Implementation of explicit lift operator** + minor walker docs update: ~1 session, post-M-α.
- **Blog post**: ~1 session of writing + review.
- **Paper draft**: ~3 months of research-grade writing, not in scope for the substrate engineering work.

## Open questions

**Q1: Should descent `◇T → □T` ever be possible?**

The default answer is *no* — modal logic forbids it because the information isn't recoverable. But there's a principled exception: a `freezeAtCompileTime[T](d: Dynamic[T], proof: SomeCompileTimeProofOfFreezability): Signal[T]` could discharge a descent given a static proof that the `◇` value is actually compile-time-knowable. This is exotic and probably not worth the substrate complexity. Defer until a real consumer asks.

**Q2: How does the modality interact with the linear-tier-under-re-execution open question (#3)?**

The re-execution question becomes "is the linearity modality `!T` interpreted per-execution (consumable once per re-execution) or per-lifetime (consumable once across the binding's entire life)?" This is a modal question — different modal frames give different semantics. The substrate may need to offer both as distinct modalities. Defer to direction #3's RFC; this RFC just provides the vocabulary.

**Q3: Should `liftDynamic` be a macro, a proc, or an implicit converter?**

Currently implicit via the walker's silent acceptance. Making it explicit (proc with `{.gcsafe.}`) gives substrate consumers a place to land cross-modality typing checks. Making it a macro lets us discharge the modality check at compile time. Lean: proc with future-extension hooks; the macro form is overkill for now.

## What this RFC does NOT do

- It does not rename `Signal[T]` to `Necessity[T]` or `Dynamic[T]` to `Possibility[T]`. The current names work; the modal interpretation is documentary, not API-breaking.
- It does not implement any new modality (transactions / refinement / etc.). Each direction owns its own implementation; this RFC gives them the shared vocabulary.
- It does not introduce a `freeze` / descent operator. Open question Q1 defers indefinitely.
- It does not gate fresco's user-facing API on the modal framing. fresco app authors continue writing `Signal[T]` and `Dynamic[T]`; the modal interpretation lives in the substrate documentation.

## Acceptance

This RFC is the deliverable. Implementation work lands as:

- **M-δ #88** (collection algebra unification, Option C): modality-polymorphic `derive`/`keep`/`fold`.
- **M-α #80** (walker pass-registry): the registration shape inherits modal framing.
- Future per-direction RFCs adopt the modality vocabulary for their contract specification.

## Decision log

- **2026-05-28** — RFC drafted. Picks Davies-Pfenning judgmental modality over Pfenning-Davies categorical (more accessible to substrate authors), over guarded type theory (covers #46 but not the other directions), over arrow calculus (FRP-historic but less general). Defers `freeze` operator question. Defers paper; ships blog-post-grade framing first.
