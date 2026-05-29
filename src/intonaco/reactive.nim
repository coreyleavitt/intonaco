## intonaco's reactive substrate — consumer surface.
##
## The canonical user-facing entry point. Imports the three layers' user-
## visible surfaces and re-exports them as one cohesive API. Consumers (fresco
## app authors, sinopia, etc.) should `import intonaco/reactive` rather than
## reaching into the layered paths directly.
##
## What's NOT here: substrate-internal constructors (computedC/effectC,
## createComputed/createEffect, the AST utilities, the walker primitives).
## Substrate-template authors who need those should `import intonaco/substrate`
## instead — the deep aggregator that exposes primitives/ + analysis/.
##
## Surface discipline:
## - Three canonical paths per tier (M-β).
##   * Sources:        `signals:` / `collections:`
##   * Static derived: `computed name, [deps]: body` / `effect [deps]: body`
##                     / `scan` / `derive` / `keep` / `fold`
##   * Dynamic derived: `dynamic name: body` / `eachItem`
## - Lifecycle:        `withScope` / `createRoot` / `onCleanup` / `dispose`
##                     / `provide` / `use` / `mountWhen` (via task/mount)
## - Transactional:    `speculative:`
## - Animation:        `tween` / `spring`
##
## Things outside this aggregator (e.g. direct use of primitives/runtime) are
## a smell signal in consumer code. They're legitimate for substrate authors.

# Primitives — user-facing types and source DSLs
import ./reactive/primitives/signal
import ./reactive/primitives/collection
import ./reactive/primitives/scope
import ./reactive/primitives/context
import ./reactive/primitives/speculative
import ./reactive/primitives/height
export signal, collection, scope, context, speculative, height

# DSL macros — the canonical-path surface
import ./reactive/dsl/binding
import ./reactive/dsl/scan
import ./reactive/dsl/derive
import ./reactive/dsl/dynamic
import ./reactive/dsl/animation
import ./reactive/dsl/each
export binding, scan, derive, dynamic, animation, each

# Capabilities (stays at reactive/ for now; revisit when #3 lands)
import ./reactive/capabilities
export capabilities
