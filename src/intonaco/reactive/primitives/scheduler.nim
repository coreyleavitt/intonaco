## Reactive scheduler — height-ordered propagation worklist + deferred-action queue.
##
## The substrate-internal scheduler. Owns:
##
## - **The reactive worklist** (`gQueue`): a height-ordered queue of `Computation`s
##   to fire. `notify(s: Subscribable)` enqueues every observer of `s`; `drainQueue`
##   pops in min-height order so every dep settles before its dependents fire —
##   glitch-free by construction.
##
## - **The deferred-action queue** (`gDeferred`): the "decide / act" seam from
##   M10. `runAfterPropagation(action)` enqueues `action` to run AFTER the reactive
##   worklist quiesces. Opaque/async/I/O work that responds to reactive change
##   lives here instead of inside an `effect`/`computed` body where the walker
##   (rightly) rejects opaque callees. The drain interleaves: the reactive
##   worklist runs to quiescence, then one deferred batch fires, then the
##   reactive worklist again (deferred actions may write signals), and so on
##   until both empty.
##
## Single-chronos-dispatcher invariant (`fresco/CLAUDE.md` non-negotiable): the
## scheduler state is threadvar-local; multi-thread embedders are unsupported.
## `runAfterPropagation` is `{.gcsafe.}` via cast — sound because the cast holds
## under the single-dispatcher invariant.
##
## Walker treatment: `runAfterPropagation` is annotated
## `{.forbids: [ReactiveRead, ReactiveWrite].}` so the walker accepts the call
## inside an `effect`/`computed` body. The closure body it receives is a lambda,
## which the walker skips (lambda bodies = deferred-execution context).


# --- Reactive worklist ------------------------------------------------------

var gPropagating* {.threadvar.}: bool
  ## True while `drainQueue` is running. Exposed for substrate-internal
  ## primitives that need to know whether they're inside a propagation
  ## (e.g. `runAfterPropagation`'s "now or later" branch).

var gQueue {.threadvar.}: seq[Computation]
  ## Height-ordered propagation worklist (dispatcher-local; the single-
  ## dispatcher invariant makes a threadvar correct). Spike uses a
  ## linear min-height scan — fine for the small graphs under test; the
  ## production form is a bucketed-by-height array (see RFC "Nim leverage").

# --- Deferred-action queue --------------------------------------------------

type DeferredAction* = proc() {.closure.}
  ## Action enqueued by `runAfterPropagation`. Drained on the single-chronos-
  ## dispatcher thread; the substrate casts gcsafe and swallows exceptions
  ## around the invocation. The single-dispatcher invariant (fresco/CLAUDE.md)
  ## makes the gcsafe cast sound; the swallow matches `drainQueue`'s existing
  ## handling of raising observers. User code does NOT need to annotate the
  ## closure — captures of globals work.

type DeferredHandle* = ref object
  ## Opaque cancellation handle returned by `runAfterPropagation`. Substrate
  ## consumers cancel through `cancel(h)` / observe with `cancelled(h)`; the
  ## internal shape (scope binding, fired flag) is not exposed because
  ## per-scope queue / priority work is a deliberate M-γ.2 non-goal — keeping
  ## the fields private lets future revisions reshape the binding without
  ## breaking call sites.
  cancelledFlag: bool

proc cancel*(h: DeferredHandle) {.gcsafe, raises: [].} =
  ## Cancel a pending deferred action. Idempotent: re-cancelling, or
  ## cancelling after the action has already fired (or been skipped because
  ## it ran outside propagation), is a no-op.
  if h != nil: h.cancelledFlag = true

proc cancelled*(h: DeferredHandle): bool {.gcsafe, raises: [].} =
  ## True iff `cancel(h)` was called on this handle. Always false for
  ## handles returned outside propagation (the action ran synchronously
  ## and there was nothing to cancel).
  h != nil and h.cancelledFlag

var gDeferred {.threadvar.}: seq[DeferredAction]
  ## Actions enqueued via `runAfterPropagation` during a `c.run()` — drained
  ## AFTER the reactive worklist settles. This is the substrate's "decide
  ## then act" seam: opaque/async work (task spawn, journal-driven side
  ## effects, I/O) lives in a deferred closure rather than inside an
  ## `effect`/`computed` body where the walker would (rightly) reject it.
  ## Implements direction (C) of the M10 substrate-design discussion.

proc runAfterPropagation(action: DeferredAction): DeferredHandle
    {.discardable, gcsafe, raises: [],
      forbids: [ReactiveRead, ReactiveWrite].} =
  ## Schedule `action` to run after the current propagation cycle drains.
  ##
  ## Inside an `effect`/`computed` body, this is the principled way to invoke
  ## opaque side effects (spawning a task, performing I/O). The body itself
  ## stays a pure decision; the action runs in the post-settle phase where
  ## `gPropagating` is still true but the worklist has emptied — nested
  ## writes from the action re-enter `notify`, which sees the flag set and
  ## simply enqueues, so `drainQueue` picks them up on its next outer
  ## iteration.
  ##
  ## Called outside any propagation, runs immediately (semantically: "after
  ## the graph settles" — outside propagation, the graph is already settled).
  ##
  ## Walker treatment: this proc is `{.forbids: [ReactiveRead, ReactiveWrite].}`
  ## so the walker accepts the call. The closure body is not descended into
  ## (lambda bodies are deferred-execution context).
  {.cast(gcsafe).}:
    let h = DeferredHandle(cancelledFlag: false)
    if currentScope != nil and not currentScope.disposed:
      # Scope-affine: scope dispose auto-cancels the pending action.
      let cap = h
      onCleanup proc() = cap.cancelledFlag = true
    if gPropagating:
      let cap = h
      let act = action
      gDeferred.add proc() =
        if not cap.cancelledFlag:
          act()
    else:
      try: action()
      except Exception: discard
    return h

proc runAfterPropagationDetached(action: DeferredAction): DeferredHandle
    {.discardable, gcsafe, raises: [],
      forbids: [ReactiveRead, ReactiveWrite].} =
  ## Like `runAfterPropagation`, but bypasses the scope-affine binding.
  ## Scope dispose will NOT cancel the returned handle — only an explicit
  ## `cancel(h)` will. Use for substrate-internal work whose lifecycle
  ## is intentionally decoupled from any reactive scope (module-level
  ## metric flushes, the substrate's own disposers).
  ##
  ## Walker treatment matches `runAfterPropagation` (the body is a
  ## lambda; the walker skips lambda bodies).
  {.cast(gcsafe).}:
    let h = DeferredHandle(cancelledFlag: false)
    if gPropagating:
      let cap = h
      let act = action
      gDeferred.add proc() =
        if not cap.cancelledFlag:
          act()
    else:
      try: action()
      except Exception: discard
    return h

# --- Drain + notify ---------------------------------------------------------

proc drainQueue() {.gcsafe, raises: [].} =
  ## Drain the worklist in height order, then drain the deferred-action queue,
  ## interleaving until both are empty. Assumes `gPropagating` is already set
  ## by `notify`, so nested writes during a `run()` (or a deferred action)
  ## enqueue rather than recurse — a node only fires after every lower-height
  ## dependency has settled. Raising observers and deferred actions are
  ## swallowed (a faulty observer/action must not break siblings or the
  ## writing task).
  ##
  ## Interleave rationale: deferred actions may write signals (the whole point
  ## of `runAfterPropagation` is to host opaque-but-non-reactive work like
  ## task spawn, which itself eventually writes to journal-derived signals).
  ## Those writes re-enqueue computations into `gQueue`. The outer loop drains
  ## reactive work to quiescence before each deferred batch, so observers
  ## always see consistent snapshots between batches.
  {.cast(gcsafe).}:
    while gQueue.len > 0 or gDeferred.len > 0:
      # Drain the reactive worklist to quiescence first.
      while gQueue.len > 0:
        # Extract the minimum-height still-queued Computation.
        var mi = 0
        for i in 1 ..< gQueue.len:
          if gQueue[i].height < gQueue[mi].height: mi = i
        let c = gQueue[mi]
        gQueue.del(mi)          # swap-remove; order irrelevant (we min-scan)
        c.inQueue = false
        if not c.disposed:
          # Effect firewall: an observer's effects are fired BY THE SCHEDULER,
          # not by the code that wrote the signal, so they must not leak into
          # the writer's inferred `tags`. Without this every `set` caller
          # inherits the catch-all `RootEffect` (observers do arbitrary
          # things), defeating `RootEffect`-as-opacity-signal in the
          # classifier. cast(tags:[]) strips it; runtime is unchanged.
          try:
            {.cast(tags: []).}:
              c.run()
          except Exception: discard
      # Reactive graph is now quiescent. Drain ONE batch of deferred actions
      # (snapshot to avoid mid-iteration mutation if an action itself calls
      # `runAfterPropagation` — those go into the next batch).
      if gDeferred.len > 0:
        let batch = gDeferred
        gDeferred = @[]
        for action in batch:
          try:
            {.cast(tags: []).}:
              action()
          except Exception: discard

proc reactivePendingCount*(): int {.gcsafe, raises: [].} =
  ## Combined depth of the reactive worklist and the deferred-action queue.
  ## Read-only observability probe (see `fresco/docs/rfc-headless-quiescence.md`
  ## Design §1) — useful beyond testing, e.g. sinopia builds its own drain
  ## from this and `reactiveIdle` rather than reusing fresco's headless
  ## driver.
  {.cast(gcsafe).}:
    gQueue.len + gDeferred.len

proc reactiveIdle*(): bool {.gcsafe, raises: [].} =
  ## True iff no propagation is in flight and both queues are empty.
  ##
  ## intonaco propagation is synchronous: `notify` drains `gQueue` and
  ## `gDeferred` on the writer's stack before returning, so from OUTSIDE
  ## propagation this is always true once a `.set()` call has returned.
  ## It is only observably false from INSIDE propagation — an
  ## effect/computed body (or a `runAfterPropagation` action) fired
  ## mid-drain, where `gPropagating` is still set.
  {.cast(gcsafe).}:
    not gPropagating and gQueue.len == 0 and gDeferred.len == 0

proc notify(s: Subscribable) {.gcsafe, raises: [].} =
  ## Enqueue every Computation observing `s` into the height-ordered worklist;
  ## if no propagation is in flight, drain it.
  {.cast(gcsafe).}:
    s.observers.iterRO c:
      if not c.disposed and not c.inQueue:
        c.inQueue = true
        gQueue.add c
    if gPropagating: return
    gPropagating = true
    try:
      drainQueue()
    finally:
      gPropagating = false
