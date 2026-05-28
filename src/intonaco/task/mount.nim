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
##   let active = signal(false)
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
import intonaco/reactive/signal
import intonaco/reactive/scope
import intonaco/reactive/binding   # effect macro
import ./core

template mountWhen*(boolSig: Signal[bool], body: untyped): untyped =
  ## Mount `body` (which must produce a `Mount`) while `boolSig` is true.
  ##
  ## The effect body fires from `notify`, not from any task — the dispatcher's
  ## `currentScope` at that point is whatever the last coroutine left behind
  ## (often nil). We capture the registering scope's context here and restore
  ## it around the effect body so `spawn`s inside `body` parent to the right
  ## place and journal events attribute to the right task.
  let mountWhenCtx = currentContext()
  var currentMount: Mount = nil
  effect [boolSig]:
    withContext(mountWhenCtx):
      if boolSig:                       # shadowed inside the effect body
        if currentMount == nil or currentMount.future.finished:
          currentMount = body
      else:
        if currentMount != nil and not currentMount.future.finished:
          currentMount.cancel()
          currentMount = nil
  onCleanup proc() =
    if currentMount != nil and not currentMount.future.finished:
      currentMount.cancel()
      currentMount = nil

template mount*(boolSig: Signal[bool], body: untyped): untyped =
  ## DSL-form alias for `mountWhen`. `mount(active): spawn child()` reads as
  ## "mount this child when active is true."
  mountWhen(boolSig, body)
