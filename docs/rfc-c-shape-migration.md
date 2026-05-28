# RFC: C-shape substrate migration

**Status:** active, governing milestone #3 ("C-shape substrate migration").
**Author origin:** decided 2026-05-28 after a multi-round architecture review
that stress-tested the A-shape against the prestige/safety value axes and
the multi-frontend constraint.
**Supersedes (closed):** milestone #2 ("Compile-time-first hardening") and
issues #57, #58 from milestone #1.

## Decision

Migrate the binding layer from the **A-shape** (auto-tracking + compile-time
inference) to the **C-shape** (explicit declared deps + walker-enforced
no-undeclared-reads). The runtime scheduler, height carrier, scope/lifecycle
machinery, journal, collection delta machinery, and Lean proof are **kept
intact**. The classifier and effect-oracle apparatus are **deleted**.

The justifying decision and the rejected alternatives are recorded in
`feedback/decision_compile_time_first_identity.md` (memory) and in
the multi-round review captured in `reference_edge_witness_chokepoint.md`.
This RFC is the *executable* form of that decision.

## The core proposition

The A-shape paid for "implicit reactive reads with a compile-time proof" by
inferring each binding's dependency set from arbitrary Nim. That inference
is undecidable in general (Rice's theorem) and bottoms out in Nim's effect
inference being sound at the queried granularity — every callsite-dependence
or higher-order pattern was a fresh leak class, each fixable but spawning
the next.

The C-shape pays a different price: every binding declares its dependencies
in a bracket. Heights compose from each dep's `{.height.}` pragma, soundness
is **structural** instead of inferred, and three failure modes (direct
undeclared read, transitive-via-helper, opaque callee) are rejected at sem
time by a single ~30-line walker. The Lean over-approximation lemma
(`overApproxSound`, intonaco #62) — whose precondition was structurally
unreachable in A — is satisfied **by construction** in C. The dynamic tier
remains as the explicit, type-quarantined escape (`Dynamic[T]` and the
`dynamic`/`each`/`mountWhen` family) — and the cross-tier wall is enforced
at sem time by the same walker.

Validation: two spikes (`fresco/tests/spike_c_shape*` and
`fresco/tests/spike_c_dynamic.nim`) prove the static fragment (10 tests,
including compile-time-baked heights and the strict gate) and the dynamic
tier (7 tests, including per-item `each` lifecycle).

## Preserve

These files and modules **are not rewritten** and **are not reorganized**.
The migration touches them only if a downstream rewrite forces a signature
change — and even then, minimally.

| Module / file | Reason |
|---|---|
| `src/intonaco/reactive/subscribable.nim` | The scheduler. Lean proof (`proofs/Consistency.lean`) is *about this code*. Touching it invalidates the proof. |
| `src/intonaco/reactive/height.nim` | `heightOf` / `composeHeight` / `withHeight` — exactly the primitives the C-shape macros call. |
| `src/intonaco/reactive/scope.nim` | `newScope` / `withScope` / `dispose` / `onCleanup`. The lifecycle machinery `each` rides. |
| `src/intonaco/reactive/collection.nim` | Delta types + `CollectionSignal[T]` + mutation ops. `each` rides on the existing delta stream. |
| `src/intonaco/reactive/deltafloor.nim` | `onDelta` is the runtime primitive `each` and other dynamic-tier patterns subscribe through. |
| `src/intonaco/reactive/dynamic.nim` (type + `dynamicComputed` + `dynamicEffect`) | The runtime floor that the C-shape `dynamic name: body` macro wraps. The type-level quarantine the walker enforces against. |
| `src/intonaco/reactive/convergence.nim` | `CommutativeGroup` concept for `fold`. Independent of binding shape. |
| `src/intonaco/journal/*` | Orthogonal — no binding-shape coupling. |
| `src/intonaco/task/*` core (supervisor, mailbox, parallel) | Lifecycle scaffolding survives. Auto-tracking dependencies inside specific consumers get rewritten in M2; the core infra stays. |
| `proofs/Consistency.lean` (incl. `overApproxSound` from #62) | Same algorithm. Same proof. The over-approximation lemma is strictly *stronger* under C (precondition structurally satisfied). |
| `proofs/Containerfile` + `leanbox` workflow | Same proof harness. |
| `verification.nim` (Diagnostic contract) | Survives — used for emitting strict-gate errors etc. Internal-vocabulary contract is independent of inference. |

## Replace

These modules **are rewritten in place** on the C-shape substrate. The old
implementation is **deleted in the same commit** that introduces the new
one. No parallel paths, no compat shims.

| Module / file | Replacement |
|---|---|
| `src/intonaco/reactive/signal.nim` macro layer | New C-shape `signals:` macro for source declaration (already exists; pragma-bake survives). Auto-tracking `Signal.get`'s `trackRead` is **removed** (`get` becomes equivalent to `peek` for the C-shape, retaining the `ReactiveRead` tag for walker detection only — the tag's role shifts from "edge formation" to "transitive-read detection in the walker"). |
| `src/intonaco/reactive/construct.nim` (`computed:` / `effect:` / `dynamic:` macros) | Rewritten as the C-shape `computed name, [deps]: body` / `effect [deps]: body` / `dynamic name: body` macros. Implementation lifted from `fresco/tests/c_shape_lib.nim`. |
| `src/intonaco/reactive/derive.nim` (`derive` / `keep` / `fold` macros) | Same operator semantics, same delta machinery; macros rewritten to the C-shape syntax. The underlying floor (`mapped`/`filtered`/`folded`) stays. |
| `src/intonaco/reactive/scan.nim` (`scan` macro) | Same. |
| `src/intonaco/reactive/runtime.nim` | The runtime floor (`createEffect`/`createComputed`) is **demoted to a private detail** of the C-shape primitives. Still imported by `dynamicComputed` etc. — but not user-facing. |
| `src/intonaco/task/mount.nim` (`mountWhen` template) | Rewritten as a C-shape conditional mount over `effect [cond]: ...` and the existing scope-disposal machinery. ~10 lines on top of the new substrate. |
| `src/intonaco/reactive/tracked.nim` (`tracked:` / `trackedEffect` macros) | Both **deleted** — `tracked:` is replaced by the explicit dep bracket; `trackedEffect` had no callers beyond the auto-track family. |
| `tests/*` for the rewritten modules | Rewritten on the C-shape. Tests of A-shape semantics (auto-tracking) are deleted — they tested a path that no longer exists. |

## Delete

Gone in the migration. **Not soft-deprecated. Not feature-flagged. Deleted.**

| File | Reason |
|---|---|
| `src/intonaco/reactive/classify.nim` | The classifier. Inference path is the load-bearing thing the C-shape eliminates. |
| `src/intonaco/reactive/purity.nim` | The effect-purity oracle (`reactiveEffects` / `opaqueReactiveCalls`). Its job in the C-shape collapses into the `noUndeclaredSignals` walker, which is ~30 lines. |
| `tests/test_classify.nim`, `tests/test_purity.nim`, `tests/test_construct.nim`, `tests/strict_probe_*.nim`, `tests/dynamic_strict_*.nim`, `tests/height_ext.nim`, `tests/test_height.nim`, `tests/test_depth_and_backfeedback.nim`, `tests/test_effect_feedback.nim` | Tests of A-shape soundness / classifier behavior. The properties they verify either become structural in C (no test needed) or no longer exist (path deleted). New C-shape equivalents are introduced in M2. |
| Any "blessed surface vs. floor" planning artifacts (the witness chokepoint) | Already removed (`spike_witness_core.nim`, `spike_edge_witness.nim` deleted; closed issues #66, #67). |

## Phase plan

### M0 — Decisions captured (this RFC)

- [x] Close moot issues with rationale.
- [x] Open milestones #3 (this migration) and #4 (scheduler conformance).
- [x] Commit the over-approximation lemma (intonaco @ `1e3d3a2`).
- [x] **This RFC.**

### M1 — Branch + promote primitives

- Create the `c-shape` branch off `main`; tag `pre-c-shape` on `main` for rollback.
- Move spike code (`fresco/tests/c_shape_lib.nim` + the `dynamic` macro and `eachItem` from `fresco/tests/spike_c_dynamic.nim`) into `src/intonaco/reactive/`. Names by function, not by spike origin: probably `computed.nim` (the macros + walker), with the existing `dynamic.nim` extended for the macro form, and `each.nim` for the collection iteration primitive.
- Delete `classify.nim`, `purity.nim`, the auto-tracking layer of `construct.nim`, and `tracked.nim` — **in the same commit** as introducing the new primitives. No interim "both exist" state.

### M2 — Migrate consumers

- `derive` / `keep` / `fold` macros (`derive.nim`) → C-shape syntax.
- `scan` macro (`scan.nim`) → C-shape syntax.
- `mountWhen` (`task/mount.nim`) → C-shape conditional mount.
- `task/` modules that used auto-tracking → rewritten on the C-shape (each by inspection; most likely a handful of `signal.get()` reads inside coroutine bodies that just need an explicit dep bracket on the surrounding `effect`/`computed`).
- Intonaco's own tests rewritten on the C-shape. Tests of A-shape paths deleted.

### M3 — Artifacts

- Verify `proofs/Consistency.lean` still aligns (expected: no change; scheduler is unchanged).
- Update `docs/rfc-consistency-model.md` — add a "C-shape migration — A-shape retired" section that points at this RFC.
- Update `README.md`, `DESIGN.md`, `CLAUDE.md`, `AGENTS.md` to reflect the architecture.

### M4 — Atomic merge

- Run full `nimble test` + `nimble strictcheck` on the `c-shape` branch.
- Verify the Lean proof still checks clean in `leanbox`.
- Merge `c-shape` → `main` as a single coordinated PR. The merge commit includes everything in M1–M3.

### After M4 — fresco rewrite (separate milestone)

`coreyleavitt/fresco` milestone #10 ("C-shape fresco rewrite") starts. fresco's
`src/fresco/reactive/binding.nim`, `devtools/panel.nim`, examples, and tests
get rewritten on the new intonaco. Discipline mirrors this RFC: no parallel
paths, atomic merge.

## The discipline (the five anti-patterns we don't entertain)

Anywhere in the migration:

1. **No backwards-compat shims.** If a consumer broke, rewrite the consumer.
2. **No soft deprecation.** Old paths are deleted in the same commit that introduces new ones.
3. **No feature flags.** One implementation per primitive.
4. **No translation layers.** No "old API calls into new internally."
5. **No "just in case" preservation.** Trust git history.

If at any point during the rebuild the temptation is *"I'll keep this old
thing around in case we need it"* — the answer is to delete it. Either it's
needed (rebuild it on the new substrate) or it isn't (gone). Every leftover
during the active phase is the seed of a permanent leftover.

## Rollback plan

If the migration produces an outcome we don't accept:

- `pre-c-shape` tag on `main` is the rollback point.
- The `c-shape` branch is abandoned.
- No state on `main` is poisoned during the migration — atomic merge means
  the bad state never lands.

If we're already past M4 and want to revert: a `revert` commit against the
merge restores the previous tree. Trivial, by design.

## Open questions (none load-bearing)

- The name of the C-shape macro module. Candidates: `reactive/computed.nim`,
  `reactive/binding.nim`. Decided in M1 by inspection.
- Whether to expose `computedC` and `effectC` as low-level public primitives
  or keep them macro-internal. Defer to M1; the spike showed both work.

These are mechanical choices, not design questions.

## Anti-RFC

This RFC does **not** govern:

- `coreyleavitt/intonaco` milestone #4 (Scheduler refinement-conformance harness) — independent ongoing fidelity work.
- `coreyleavitt/intonaco` milestone #1 surviving issues (#3, #4, #45, #46, #60, #61, #74) — orthogonal research directions.
- `coreyleavitt/fresco` non-binding-layer work — Screen v2, devtools, terminal-interaction phases. Those continue on their own clocks.

The migration is **narrow**, **bounded**, and **does not entitle itself** to
touch anything outside its scope.
