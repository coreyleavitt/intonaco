## Signals + effects + computed values with runtime dep tracking.
##
## v2.0 implementation: Solid-flavored eager propagation. A signal
## write synchronously runs every registered observer. The compile-
## time static-graph implementation lands in v2.3 as a drop-in for
## the same surface.
##
## API:
##   let count = signalC(0)
##   count()         # read (tracked if inside an effect / computed)
##   count.set(5)    # write
##   createEffect(proc() = echo count())
##   let doubled = createComputed(proc(): int = count() * 2)
##
## Tracking: when a Signal is read inside a Computation's body, the
## Signal records the Computation as an observer; the Computation
## records the Signal as a source. On write, observers re-run. On
## scope dispose, the Computation is marked disposed and removed
## from each of its sources' observer lists.



type
  Signal*[T] = ref object of Subscribable
    val: T
    label*: string

converter toSubscribable*[T](s: Signal[T]): Subscribable = s.Subscribable
  ## Lets a `[count, doubled]` bracket of `Signal[T]` elements be passed
  ## where `openArray[Subscribable]` is expected. Lives alongside the
  ## `Signal[T]` type since the converter is structurally tied to it.

# The `ReactiveRead` / `ReactiveWrite` `tags` effects live in `subscribable`
# (they describe reactive-state access generally, not signals specifically);
# `get` / `setRaw` below declare them.

# --- Signal -----------------------------------------------------------------

proc signalC*[T](initial: T, label = ""): Signal[T] =
  ## **Substrate-internal** runtime constructor. Consumers use the
  ## `signals: name = value` DSL macro instead — `signals:` bakes the
  ## `{.height: 0.}` pragma that downstream `computed`/`effect` macros
  ## compose. Naming follows the C-shape primitive convention (compare
  ## `computedC` / `effectC`).
  ## Construct a Signal holding `initial`. The optional `label` is
  ## used by the journal for `ekSignalWrite` events — unlabeled
  ## signals are excluded from state-restoration projection.
  ##
  ## If `pendingRestoration` (see `intonaco/reactive/primitives/restoration`)
  ## contains `label`, the journal-staged value replaces `initial`
  ## (read-and-remove). Empty labels and labels not in the staging
  ## table short-circuit at one table lookup — non-restoration
  ## paths pay no perceptible cost.
  let effective = consumeRestoration(label, initial)
  Signal[T](val: effective, label: label)

proc get*[T](s: Signal[T]): T {.gcsafe, tags: [ReactiveRead].} =
  ## Read the current value. When called inside a `createEffect` /
  ## `createComputed` body, registers a dynamic dependency on `s`.
  ## Use `peek` to read without tracking.
  trackRead(s)
  s.val

proc peek*[T](s: Signal[T]): T {.gcsafe.} =
  ## Read the current value without registering a dependency on the
  ## current Computation. Use this in code that observes a signal for
  ## side-effects (animation start values, debug logs, journal writes)
  ## but doesn't want to be re-fired when the signal changes.
  s.val

proc `()`*[T](s: Signal[T]): T {.gcsafe.} = s.get()
  ## Sugar — `count()` reads + tracks; same as `count.get()`.

proc setRaw[T](s: Signal[T], v: T) {.gcsafe, raises: [], tags: [ReactiveWrite].} =
  ## The raw value mutation, isolated so it can carry the `ReactiveWrite`
  ## effect cleanly (a declared tag injects into callers). `setCore` routes
  ## its store through here, so everything calling `set` transitively carries
  ## `ReactiveWrite` — and `{.forbids: [ReactiveWrite].}` can catch it — even
  ## though `set` itself also journals and notifies (unbounded effects).
  s.val = v

proc setCore[T](s: Signal[T], newVal: T, journal: bool)
    {.gcsafe, raises: [].} =
  when compiles(s.val == newVal):
    # IEEE-754 corner: for Signal[float], `NaN != NaN` so writing NaN
    # over NaN fires observers. For ref signals, identity equality
    # (writing the same ref is a no-op). Both consistent with Nim
    # equality semantics.
    if s.val == newVal: return
  # Push a revert into the active speculative frame, if any. Captures
  # the prior value by closure so a rollback restores it AND notifies
  # observers so dependent effects re-run.
  if currentSpeculative.value != nil and not currentSpeculative.value.committed:
    let captured = s
    let prior = s.val
    onSpeculativeRevert proc() =
      captured.val = prior
      notify(captured)
  setRaw(s, newVal)
  # Suppress journaling during a time-warp projection: rewindTo
  # re-fires observers, and any effect that writes a derived signal
  # would otherwise append a fresh `ekSignalWrite` mid-rewind,
  # corrupting the historical trace. Observers still notify so the
  # cascade computes consistently — only the journal write is
  # skipped. See `journal/log.rewindingFlag` for the contract.
  if journal and not isRewinding():
    # Effect firewall (cast(tags:[])): journaling is internal substrate
    # bookkeeping (TimeEffect + the journal's RootEffect), not a *reactive*
    # effect of the writing code. Stripping it — together with the observer
    # firewall in notify — leaves `set` carrying only ReactiveWrite, so a bare
    # `RootEffect` in a body's tags cleanly means "the compiler punted"
    # (opacity), never "this wrote a signal." Runtime unchanged.
    {.cast(gcsafe), cast(tags: []).}:
      let valRepr =
        when compiles($newVal): $newVal
        else: ""
      journalEvent:
        jrnl.logSignalWrite(taskTid, parentEvt, s.label, valRepr)
  notify(s)

proc set*[T](s: Signal[T], newVal: T) {.gcsafe, raises: [].} =
  ## Write `newVal` to the signal. Notifies observers and records a
  ## journal entry under the current scope (if any).
  s.setCore(newVal, journal = true)

proc setUntracked[T](s: Signal[T], newVal: T) {.gcsafe, raises: [].} =
  ## Like `set` but **does not write a journal entry**. Used by the
  ## animation frame clock for intermediate interpolation values:
  ## those writes have no meaningful task attribution (the clock has
  ## no owning user scope) and would bloat the journal anyway. The
  ## terminal animation frame should still go through `set` so the
  ## settled value is journaled.
  s.setCore(newVal, journal = false)

template `:=`*[T](s: Signal[T], v: T): untyped =
  ## DSL sugar for signal writes: `count := 5` ≡ `count.set(5)`.
  s.set(v)

macro signals*(body: untyped): untyped =
  ## Declare one or more signals in a colon block:
  ##
  ##   signals:
  ##     count = 0
  ##     title = "hello"
  ##
  ## Named `signals` rather than `state` because chronos exports
  ## `state*(future)` returning FutureState — overload resolution
  ## would shadow our macro any time `import chronos` is in scope.
  ## Single-line `signals x = 0` is not supported — Nim's parser
  ## claims that shape as a named-arg call.
  expectKind(body, nnkStmtList)
  result = newStmtList()
  for stmt in body:
    case stmt.kind
    of nnkAsgn:
      let name = stmt[0]
      let value = stmt[1]
      let labelLit = newLit($name)
      # Bake {.height: 0.} on the source binding so a computed reading it can
      # resolve a static height (#51/#53). Sources are height 0 by definition.
      result.add nnkLetSection.newTree(nnkIdentDefs.newTree(
        withHeight(name, 0), newEmptyNode(),
        newCall(bindSym"signalC", value,
                nnkExprEqExpr.newTree(ident"label", labelLit))))
    else:
      error("signals: arm must be `name = value`; got " &
            stmt.repr, stmt)
