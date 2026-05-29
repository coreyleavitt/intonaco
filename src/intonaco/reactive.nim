{.experimental: "callOperator".}

## intonaco's reactive substrate — **consumer surface**.
##
## The canonical user-facing entry point. Re-exports ONLY the canonical-path
## API: source DSLs (`signals:`, `collections:`), derivation macros (`computed`,
## `effect`, `scan`, `derive`, `keep`, `fold`, `dynamic`), accessors, lifecycle
## primitives, animation, speculative scopes, `each`, the `cap` system, and
## `converge` for cross-write merging.
##
## Substrate-internal constructors and machinery are NOT re-exported here:
## - `signalC(value, label)` / `collectionC(value, label)` (use `signals:` /
##   `collections:`)
## - `computedC` / `effectC` / `createComputed` / `createEffect` /
##   `dynamicComputed` / `dynamicEffect` (the kit and macros use these)
## - `onDelta` / `mapped` / `filtered` / `folded` / `deltas` / `foldDeltas`
##   (the delta floor — use `derive`/`keep`/`fold`/`scan`/`each`)
## - `subscribe` / `notify` / `runAfterPropagation` / `Subscribable` ops
## - `restoration`, `Computation`, `Height` pragma, etc.
##
## Substrate authors (sinopia, future research-direction modules, fresco's
## bindings) use `intonaco/substrate` instead — the full substrate-author
## surface that includes everything in `intonaco/reactive` PLUS the
## primitives, the kit, the analysis pass machinery, and the diagnostic
## contract.
##
## See `intonaco/docs/surface-discipline.md` for the formal three-canonical-
## paths-per-tier discipline and the canonical-vs-internal map.

# --- Sources ---------------------------------------------------------------
# `signals:` macro for scalar sources; `collections:` for collection sources.
# Each declared source bakes height 0; downstream heights compose at compile
# time.
#
# Discipline at the naming level: substrate-internal primitives carry the
# `C` suffix (`signalC` / `collectionC` / `computedC` / `effectC`). Consumers
# never use the C-suffixed names — they use the corresponding DSL macro
# (`signals:` / `collections:` / `computed` / `effect`). The C-suffix is
# visible in `intonaco/reactive` but mechanically signals "substrate use only."
# See `docs/surface-discipline.md`.
import ./reactive/primitives/signal
export signal

import ./reactive/primitives/collection
export collection

# --- Static derived --------------------------------------------------------
# `computed name, [deps]: body` / `effect [deps]: body` / `scan` / `derive` /
# `keep` / `fold` — walker-checked, height-baked.
import ./reactive/dsl/binding
export binding

import ./reactive/dsl/scan
export scan

import ./reactive/dsl/derive
export derive

# --- Dynamic derived -------------------------------------------------------
# `dynamic name: body` — runtime-tracked binding (the ◇ modality).
import ./reactive/dsl/dynamic
export dynamic

# --- Collection higher-level ----------------------------------------------
# `eachItem` — per-item scope spawn over a CollectionSignal.
import ./reactive/dsl/each
export each

# --- Lifecycle -------------------------------------------------------------
# `Scope`, `newScope`, `withScope`, `onCleanup`, `dispose`, `createRoot`.
import ./reactive/primitives/scope
export scope

# `provide` / `use` / `tryUse` for context propagation through the scope tree.
import ./reactive/primitives/context
export context

# `speculative:` macro + `rollback`. Internal hooks (onSpeculativeRevert /
# onSpeculativeRollback / onSpeculativeCommit) are substrate-internal — they
# let primitive types participate in speculation; consumers use the macro.
import ./reactive/primitives/speculative
export speculative

# --- Animation -------------------------------------------------------------
# `tween` / `spring` for animation-curve-driven signal updates.
import ./reactive/dsl/animation
export animation

# --- Convergence -----------------------------------------------------------
# `converge` for cross-write merging via the convergence algebra.
# The CommutativeMonoid / Joinable / CommutativeGroup concepts and the law-
# witness helpers (holds*) are substrate-internal — used by derive/fold.
import ./reactive/primitives/convergence
export convergence

# --- Capabilities ----------------------------------------------------------
import ./reactive/capabilities
export capabilities
