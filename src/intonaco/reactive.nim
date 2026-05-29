## intonaco's reactive substrate — consumer surface.
##
## Imports the substrate as a real Nim module and re-exports its
## `*`-marked symbols. Consumers `import intonaco/reactive` and get the
## curated public surface; substrate-internal symbols (non-`*` in the
## include-set) stay invisible.
##
## Type identity: because consumers reach the substrate through `import`
## (not `include`), all consumers share the SAME compiled
## `reactive_internal` module. Signal[T] / CollectionSignal[T] / Scope
## have one canonical identity across the consumer graph.
##
## Substrate-internal tests that need access to private symbols (and the
## same type identities as the substrate-author code they exercise) do
## `include intonaco/reactive_internal` and run in their own compilation
## unit, where the whole substrate is inlined.

import intonaco/reactive_internal
export reactive_internal
