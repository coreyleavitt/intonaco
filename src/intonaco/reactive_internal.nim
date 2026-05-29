{.experimental: "callOperator".}

## intonaco's reactive substrate.
##
## This is the entire reactive substrate as ONE Nim module. Files in
## `reactive/primitives/` and `reactive/dsl/` are organized for editing
## but compose into one module via `include`. The `*`-export marker is
## the actual public/private boundary — `*`-exported symbols are the
## consumer surface, everything else is private to the substrate.
##
## Static is the unmarked default — `signals:`, `collections:`,
## `computed name, [deps]: body`, `effect [deps]: body`, `derive`/
## `keep`/`fold`/`scan`. Dynamic is the marked escape — `dynamic name:
## body`, `Dynamic[T]`, `DynamicCollection[T]`, `eachItem`. The walker
## quarantines dynamic-typed reads inside static bindings (modal
## coherence).
##
## See `docs/seams.md` for the decide/act seam (opaque async/IO work),
## `docs/rfc-c-shape-migration.md` for the consistency model,
## `docs/rfc-modal-tiers.md` for the modal framing.

# --- External dependencies ----------------------------------------------
# Hoisted to the parent so the include-files don't redundantly import.
# Inside the include-set, these names resolve via the parent's scope.
import std/[macros, options, sequtils, math, strutils, tables]
import chronos
import chronos/contextvars
import intonaco/journal/events
import intonaco/journal/log

# Analysis layer stays modular — separate concern (walker passes,
# diagnostic contract). The reactive include-set imports them; consumers
# don't see them via this module.
import ./reactive/analysis/pass
import ./reactive/analysis/passes_core   # registers the three core walker passes at module init
import ./reactive/analysis/ast

# Capabilities — separate module, consumer-facing. Re-export so
# `import intonaco/reactive` surfaces the cap concepts.
import ./reactive/capabilities
export capabilities

# Results — Task/group's `Result[Mount, GroupError]` needs it.
import results
export results

# std/sets — needed by task/supervisor.
import std/sets

# --- Substrate include-set ----------------------------------------------
# Order respects forward references. Each included file's `*`-exported
# symbols become this module's exports; non-`*` symbols are private to
# the substrate (sealed from consumers by Nim's module visibility).

# Layer 1: foundational types + walker pragmas
include reactive/primitives/height
include reactive/primitives/subscribable

# Layer 2: scopes + scheduler (decide/act seam)
include reactive/primitives/scope
include reactive/primitives/scheduler

# Layer 3: scope-derived primitives
include reactive/primitives/journal_glue   # journalEvent + journalEventOnScope (depend on Scope + globalJournal)
include reactive/primitives/restoration
include reactive/primitives/context
include reactive/primitives/speculative

# Layer 4: signal + collection sources and the dynamic tier
include reactive/primitives/signal
include reactive/primitives/dynamic
include reactive/primitives/collection
include reactive/primitives/convergence

# Layer 5: runtime floor + delta floor
include reactive/primitives/computation
include reactive/primitives/runtime
include reactive/primitives/deltafloor

# Layer 6: DSL macros (substrate-template authoring layer)
include reactive/dsl/kit
include reactive/dsl/binding
include reactive/dsl/scan
include reactive/dsl/derive
include reactive/dsl/dynamic
include reactive/dsl/each
include reactive/dsl/animation

# Layer 7: task system — spawn / Mount / mountWhen / supervisor.
# Substrate-author code that uses the reactive scheduler + scope.
# Folded into the include-set so substrate-internal tests can use task
# primitives without crossing module boundaries that would break type
# identity.
include task/types
include task/core
include task/mailbox
include task/group
include task/parallel
include task/mount
include task/supervisor

# Layer 8: journal/timewarp — replay-time signal restoration.
# Uses substrate-internal `setUntracked` to write signals without
# producing journal entries. Substrate-author code; folded in for
# the same type-identity reason as task/*.
include intonaco/journal/timewarp
