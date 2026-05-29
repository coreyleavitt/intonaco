## Reactive conditional mount: `mountWhen(boolSig): body`.
##
## While `boolSig` evaluates to `true`, the body (which produces a Mount —
## typically `spawn child()`) is kept alive. When the signal flips to false,
## the current Mount is cancelled. On a true flip after a cancel, a fresh
## Mount is spawned. On scope dispose, the active Mount is cancelled along
## with the rest of the cleanup chain.
##
## ## Shape
##
##   let active = signalC(false)
##   mountWhen(active):
##     spawn worker()
##
## For compound conditions, compose via a `computed`:
##
##   computed shouldRun, [active, depth]:
##     active and depth < 10
##   mountWhen(shouldRun):
##     spawn worker()
##
## Under the C-shape direction, `boolSig` is the single declared dependency —
## the explicit-deps discipline (no auto-tracking of arbitrary `cond` reads)
## means compound conditions get their own named binding. The mount logic
## itself rides on the existing `effect [boolSig]: ...` macro from `binding`.

import chronos/contextvars
import intonaco/reactive/primitives/signal
import intonaco/reactive/primitives/scope
import intonaco/reactive/dsl/binding       # effect macro
import intonaco/reactive/primitives/subscribable  # runAfterPropagation — the decide/act seam
import ./core

template mountWhen*(boolSig: Signal[bool], body: untyped): untyped =
  ## Mount `body` (which must produce a `Mount`) while `boolSig` is true.
  ##
  ## Decide / act seam (M10 direction C):
  ##   * The `effect [boolSig]:` body computes ONLY the decision (the bool
  ##     value of `boolSig` at this propagation). It is walker-clean by
  ##     construction — no opaque/async call inside it.
  ##   * The actual spawn / cancel runs through `runAfterPropagation` in a
  ##     deferred closure. The closure is a lambda; the walker skips lambda
  ##     bodies (their reads execute in a separate reactive frame, draining
  ##     after the worklist quiesces).
  ##
  ## The effect fires from `notify`, not from any task — the dispatcher's
  ## `currentScope` at that point is whatever the last coroutine left behind
  ## (often nil). We capture the registering scope's context here and restore
  ## it inside the deferred closure so `spawn`s inside `body` parent to the
  ## right place and journal events attribute to the right task.
  let mountWhenCtx = currentContext()
  var currentMount: Mount = nil
  var disposed = false
  effect [boolSig]:
    let should = boolSig         # decide: pure bool snapshot
    runAfterPropagation(proc() {.closure.} =
      if disposed: return
      withContext(mountWhenCtx):
        if should:
          if currentMount == nil or currentMount.future.finished:
            currentMount = body
        else:
          if currentMount != nil and not currentMount.future.finished:
            currentMount.cancel()
            currentMount = nil)
  onCleanup proc() =
    disposed = true
    if currentMount != nil and not currentMount.future.finished:
      currentMount.cancel()
      currentMount = nil

template mount*(boolSig: Signal[bool], body: untyped): untyped =
  ## DSL-form alias for `mountWhen`. `mount(active): spawn child()` reads as
  ## "mount this child when active is true."
  mountWhen(boolSig, body)
