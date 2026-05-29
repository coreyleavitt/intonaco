# intonaco surface discipline — the canonical-path API

**Status**: Canonical reference (M-β, milestone #6)
**Companion to**: `docs/extension-protocol.md` (substrate-author surface), `docs/rfc-c-shape-migration.md` (the substrate this discipline organizes)
**Tracking issue**: coreyleavitt/intonaco#84

This document defines intonaco's **three canonical paths per tier** discipline and the **consumer vs substrate-author surface split** that the two aggregators (`intonaco/reactive` and `intonaco/substrate`) enforce.

If you're writing app code (a fresco app, a sinopia app, future-frontend consumer): read this. The discipline tells you which path each construction takes.

If you're extending the substrate (sinopia's bindings, a research-direction module, a custom DSL macro family): read `docs/extension-protocol.md` first; this document is the consumer-side complement.

## The thesis

> **Three tiers, three canonical paths per tier.** Source declaration; static derivation; dynamic derivation. Every reactive thing an app creates flows through one of these three paths. Substrate-internal primitives carry the `C` suffix (`signalC`, `collectionC`, `computedC`, `effectC`) — visible to substrate authors, named to flag substrate use to anyone glancing at code.

The discipline is **naming-level**, not import-level. The runtime primitive constructors are reachable through `intonaco/reactive` (consumer aggregator) AND `intonaco/substrate` (substrate-author aggregator) — but the `C` suffix on `signalC` / `collectionC` / `computedC` / `effectC` tells the reader "this is the C-shape primitive, not for app code." App authors who type `signal(0)` by habit get an undefined-identifier error and reach for the canonical `signals: x = 0`.

This is the same discipline as `computedC` vs `computed` that's existed since the C-shape migration. M-β extends the C-suffix naming to source constructors (`signalC` / `collectionC`) so the discipline is uniform.

## The three canonical paths

### Tier 1: Sources

| Path | Canonical | Substrate-internal |
|---|---|---|
| Scalar source | `signals: name = value` | `signalC(value, label)` |
| Collection source | `collections: name = value` | `collectionC(value, label)` |

The `signals:` and `collections:` macros bake `{.height: 0.}` on each declared source. Downstream `computed` / `effect` / `scan` / `derive` resolve heights compositionally over those baked sources.

Direct use of `signalC` / `collectionC` skips the height baking — the resulting signal is runtime-only. Substrate templates (sinopia's `traceSignal`, mountWhen's internal state tracking) use them directly; consumers should not.

### Tier 2: Static derivation

| Path | Canonical | Substrate-internal |
|---|---|---|
| Scalar derivation | `computed name, [deps]: body` | `computedC(deps, body, fixedHeight)` |
| Void side effect | `effect [deps]: body` | `effectC(deps, body, fixedHeight)` |
| Collection delta fold | `scan name, coll, [deps], initial, step` | (uses `foldDeltas` internally) |
| Collection map / filter / aggregate | `derive` / `keep` / `fold` | (uses `mapped` / `filtered` / `folded` internally) |

The macros run the C-shape walker analysis (M-α.2 platform), bake `{.height.}` pragmas at compile time, and emit the runtime primitive call. Consumer code is walker-checked; substrate-internal call sites are not.

### Tier 3: Dynamic derivation

| Path | Canonical | Substrate-internal |
|---|---|---|
| Scalar dynamic binding | `dynamic name: body` | `dynamicComputed(body)` |
| Void dynamic effect | (use `dynamic name: body` + a sink read) | `dynamicEffect(body)` |
| Per-item iteration | `eachItem(coll, body)` | (uses internal scope spawn) |

The dynamic tier is the `◇T` modality (see `docs/rfc-modal-tiers.md`). Bindings declared via `dynamic name: body` produce `Dynamic[T]`-typed results; cross-tier reads (a `computed` body reading a `Dynamic[_]`) are rejected by the walker. The escape is type-quarantined.

## What's NOT a canonical path

A few things consumers should NOT reach for, even though they exist:

| Primitive | Why not |
|---|---|
| `createComputed` / `createEffect` | runtime floor — no walker analysis, no height baking; substrate-template kit (M-α.3) is the right wrapper layer |
| `onDelta` / `mapped` / `filtered` / `folded` / `deltas` / `foldDeltas` | delta floor — use `derive`/`keep`/`fold`/`scan`/`each` instead |
| `subscribe` / `notify` / `unsubscribeAll` | direct observer machinery — `computed`/`effect` handle subscription internally |
| `runAfterPropagation` | the decide/act seam — substrate-template machinery; consumers use `mountWhen` and similar templates that wrap it |
| `setUntracked` | journal-suppressed write — animation frame clock internal; consumer code uses `set` / `:=` |

If you find yourself reaching for one of these in app code, ask: "is this substrate-template work?" If yes, you're a substrate author; switch to the substrate aggregator (`docs/extension-protocol.md`). If no, find the canonical path that does what you want.

## Lifecycle (canonical across all tiers)

These primitives are canonical for app code regardless of which tier of derivation is in play:

| Concern | Canonical |
|---|---|
| Scope ownership | `Scope`, `newScope`, `withScope`, `onCleanup`, `dispose`, `createRoot` |
| Context propagation | `provide(value)`, `use(T)`, `tryUse(T)` |
| Transactional rollback | `speculative: body`, `rollback(scope)` |
| Animation | `tween(signal, target, duration)`, `spring(signal, target)` |
| Cross-write merge | `converge(writes)` |
| Capabilities | `cap T`, `{.needs: T.}` pragma, `{.inferCaps.}` pragma, `assertCap T` |

## The two aggregators

```nim
import intonaco/reactive      # consumer surface
```

Re-exports the three canonical paths per tier plus the lifecycle / animation / cap APIs. Substrate-internal symbols (the C-suffixed constructors plus the runtime floor) are reachable through this aggregator BUT carry the C-suffix naming to flag substrate use.

```nim
import intonaco/substrate     # substrate-author surface
```

Re-exports everything in `intonaco/reactive` PLUS the analysis platform (walker pass registry, substrate kit, Diagnostic emission), the delta floor, the runtime floor, restoration, convergence concepts, and the diagnostic contract. This is the aggregator for:
- sinopia's substrate bindings
- Future research-direction modules
- fresco's internal substrate code (the bindings that build on intonaco primitives)
- Anyone writing new substrate templates via the M-α.3 kit

## Why naming-level instead of import-level?

The original M-β plan considered hiding substrate-internal constructors via selective re-export (`from M import X, Y; export X, Y`). That mechanism doesn't compose cleanly with Nim's operator-overload resolution across modules (the `:=` template, the `()` call operator, the `peek` overloads across `Signal[T]` / `ReactiveCollection[T]` / chronos's `Channel` would all need explicit per-overload routing).

The PhD-CS-honest analysis: naming-level discipline is sufficient at current scale. The substrate is small enough that intent reads off the name; the C-suffix convention is the same pattern already established for `computedC` / `effectC` since the C-shape migration. Extending it to `signalC` / `collectionC` makes the convention uniform.

If, in the future, the substrate grows to a scale where mechanical enforcement becomes necessary (multiple consumer ecosystems each with their own discipline, e.g.), the path forward is a `-d:intonacoStrictSurface` compile flag that errors on consumer use of the C-suffixed primitives. That flag is **not shipped** in M-β — defer until a real consumer requests it.

## The discipline as a checklist

If you're writing fresco app code, you should use:
- [x] `signals:` and `collections:` for sources
- [x] `computed name, [deps]: body` / `effect [deps]: body` / `scan` / `derive` / `keep` / `fold` for static derivation
- [x] `dynamic name: body` and `eachItem` for dynamic derivation
- [x] `withScope` / `onCleanup` / `createRoot` for lifecycle
- [x] `provide` / `use` / `speculative` / animation / cap APIs as needed

You should NOT use:
- [ ] `signalC` / `collectionC` / `computedC` / `effectC` (C-suffix = substrate use)
- [ ] `createComputed` / `createEffect` (runtime floor — substrate-template kit wraps it)
- [ ] `onDelta` / delta-floor procs directly (use `derive` / `scan` / `each`)
- [ ] `subscribe` / `notify` directly (the macros handle subscription)
- [ ] `runAfterPropagation` directly (substrate template machinery)

If you find yourself wanting something in the SHOULD NOT list, you've crossed into substrate-author territory. Switch to `import intonaco/substrate` and read `docs/extension-protocol.md`.

## Test discipline (M-ε.2)

Tests fall into two categories. The right `import`/`include` choice depends on which:

### Consumer tests — `import intonaco/reactive`

Tests that exercise behavior reachable through public macros. They use the same surface a fresco app sees:
- `signals:`, `collections:`, `computed`, `effect`, `derive`, `keep`, `fold`, `scan`, `dynamic`, `eachItem`, `eachDelta`
- `Scope`, `withScope`, `onCleanup`, `createRoot`
- `tween`, `spring`, `speculative:`, `provide`/`use`
- `Signal[T]`, `CollectionSignal[T]`, `Dynamic[T]`, `DynamicCollection[T]`, `Subscribable` (types only)

These tests should NEVER reach for substrate-internal procs (`createEffect`, `onDelta`, `subscribe`, `notify`, `pushDelta`, `setUntracked`, `runAfterPropagation`, `mapped`/`filtered`/`folded`, etc.). If a behavior CAN be tested through the public surface, the test belongs in this category.

### Substrate-internal tests — `include intonaco/reactive_internal`

Tests that exercise substrate-floor behavior with no public macro equivalent:
- **Walker-rejected patterns**: effect-writes-signal (`createEffect` body that calls `someSignal.set(...)`). The walker correctly rejects these through `effect [deps]: body` because the written signal isn't in the deps bracket. Testing the substrate's tolerance of this pattern requires the floor procs.
- **Substrate-template kit**: `computedC`, `effectC`, `tracedC`-style primitives. The kit is the substrate-author API; testing it requires substrate-author access.
- **Floor procs directly**: `mapped`, `filtered`, `folded`, `deltas`, `foldDeltas`, `runAfterPropagation`. These are runtime primitives the public macros wrap.
- **Construction without public seed macros**: `newDynamicReactive`, `pushDelta`. Public `dynamicCollection name: body` macro is deferred (M-δ.2); until it lands, modality tests need substrate-internal access.

These tests use `include intonaco/reactive_internal` rather than `import` because:
1. They need access to non-`*`-exported symbols (the seal makes them invisible through `import`).
2. They need the same type identities as the substrate-author code they test (Nim's `include` keeps types in the test's compilation unit; cross-import would fragment).

### How to decide

Ask: **could this test be written against the public macros without changing what's being tested?**
- If yes: it's a consumer test. Use `import intonaco/reactive`.
- If no — the public macros' walker discipline rejects the pattern, or no public macro exists yet: substrate-internal. Use `include intonaco/reactive_internal`.

Don't use `include` as a default. Reach for it deliberately when the test genuinely exercises substrate-floor behavior.

## Decision log

- **2026-05-29** — M-β closed. C-suffix naming chosen over import-level hiding after PhD-CS analysis: Nim's overload-resolution semantics don't play cleanly with selective re-export for operator overloads. Naming-level discipline is uniform with the existing `computedC` / `effectC` convention and is sufficient at current scale. `-d:intonacoStrictSurface` flag deferred (file as follow-up if requested).
- **2026-05-29** — M-ε.1 sealed the substrate via `include`-based single-module structure. The C-suffix discipline gets compiler-enforcement for everything below the `*` line. signalC/collectionC remain `*`-exported (C-suffix flags substrate intent at the call site, per the M-β decision).
- **2026-05-29** — M-ε.2 audit: 3 substrate-internal tests (`test_collection`, `test_diamond_glitch`, `test_binding`) migrated to `import intonaco/reactive` after the audit showed their intent is consumer-level. 10 tests remain substrate-internal-by-design (decide/act seam, walker-rejected effect patterns, substrate-template kit, runtime-floor primitives). Surfaced one substrate gap during migration: `peek*[T](c: ReactiveCollection[T])` added so a CollectionSignal can be used as a dep in `[deps]` brackets.
