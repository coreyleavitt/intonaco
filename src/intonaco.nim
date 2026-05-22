## intonaco — the compile-time-first reactive substrate.
##
## Imported as `import intonaco/<module>`; consumers don't typically
## `import intonaco` as a single aggregate because the substrate is
## broad (reactive, task, journal, capabilities, concurrency) and
## different consumers care about different slices.
##
## Sibling packages:
##   - fresco   — terminal frontend (depends on intonaco)
##   - sinopia  — planned trace frontend (will depend on intonaco)
##
## Key entry points:
##   - intonaco/reactive/signal       — Signal[T], createEffect
##   - intonaco/reactive/scope        — newScope, withScope, dispose
##   - intonaco/reactive/speculative  — speculative: blocks
##   - intonaco/reactive/animation    — tween / spring / frame clock
##   - intonaco/reactive/collection   — CollectionSignal[T]
##   - intonaco/reactive/context      — provide T: v / use T
##   - intonaco/reactive/capabilities — cap concept primitives
##   - intonaco/reactive/static_graph — tracked: macro
##   - intonaco/task/core             — task primitive + spawn variants
##   - intonaco/task/supervisor       — supervisor: macro + strategies
##   - intonaco/task/parallel         — parallel: structured concurrency
##   - intonaco/task/mount            — mountWhen, reactive conditional spawn
##   - intonaco/task/mailbox          — Mailbox[T] + EventSource conformance
##   - intonaco/journal/events        — Event variant + EventId / TaskId
##   - intonaco/journal/log           — append-only log + projection
##   - intonaco/journal/persist       — JSONL persistence + snapshots
##   - intonaco/journal/timewarp      — rewindTo / resumeLive
##   - intonaco/concurrency           — single-dispatcher guard
