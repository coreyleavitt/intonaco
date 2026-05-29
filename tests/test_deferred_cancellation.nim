## runAfterPropagation cancellation handles + scope-affine semantics (M-γ.2).
##
## The seam is no longer fire-once: every call returns a `DeferredHandle`
## that can be cancelled. When called inside a Scope, the handle is
## auto-cancelled by scope dispose — the substrate eliminates the
## "captured disposed flag" idiom that every mountWhen-style consumer
## would otherwise re-invent.

import std/unittest
import intonaco/reactive/primitives/scope
import intonaco/reactive/primitives/signal
import intonaco/reactive/primitives/scheduler
import intonaco/reactive/dsl/binding

suite "runAfterPropagation cancellation":

  test "tracer: returns a handle; action fires after worklist drains":
    var actionRan = false
    let trigger = signalC(0)
    discard createRoot:
      effect [trigger]:
        let _ = trigger
        let h = runAfterPropagation(proc() {.closure.} = actionRan = true)
        check h != nil
    check actionRan

  test "cancel before drain prevents action from firing":
    var actionRan = false
    let trigger = signalC(0)
    var captured: DeferredHandle = nil
    discard createRoot:
      effect [trigger]:
        let _ = trigger
        captured = runAfterPropagation(proc() {.closure.} = actionRan = true)
        captured.cancel()    # cancel before the deferred batch drains
    # The initial subscribe ran the effect outside propagation, so the
    # action above fired synchronously. Reset, then drive via a set()
    # which DOES open a propagation frame.
    actionRan = false
    trigger.set(1)
    check not actionRan
    check captured.cancelled

  test "scope-affine: scope dispose before drain cancels the action":
    # When the Scope current at the runAfterPropagation call disposes
    # before the deferred batch fires, the substrate auto-cancels — no
    # captured `disposed` flag in user code.
    var actionRan = false
    var childScope: Scope = nil
    let trigger = signalC(0)
    let rootScope = createRoot:
      # Registered in the root scope. Initial fire sees childScope=nil
      # and no-ops. After we install childScope, the disposer's deferred
      # batch entry runs first (registration order) and disposes
      # childScope, cancelling the action's scope-affine handle.
      effect [trigger]:
        let _ = trigger
        if childScope != nil:
          runAfterPropagationDetached(proc() {.closure.} = dispose(childScope))
      effect [trigger]:
        let _ = trigger
        if childScope != nil:
          let bindTo = childScope
          withScope(bindTo):
            runAfterPropagation(proc() {.closure.} = actionRan = true)
    childScope = newScope(parent = rootScope)
    actionRan = false
    trigger.set(1)
    check not actionRan

  test "detached: scope dispose does NOT cancel the action":
    var actionRan = false
    var childScope: Scope = nil
    let trigger = signalC(0)
    let rootScope = createRoot:
      effect [trigger]:
        let _ = trigger
        if childScope != nil:
          runAfterPropagationDetached(proc() {.closure.} = dispose(childScope))
      effect [trigger]:
        let _ = trigger
        if childScope != nil:
          let bindTo = childScope
          withScope(bindTo):
            runAfterPropagationDetached(proc() {.closure.} = actionRan = true)
    childScope = newScope(parent = rootScope)
    actionRan = false
    trigger.set(1)
    check actionRan

  test "cancel is idempotent; double-cancel and nil are no-ops":
    var actionRan = false
    let trigger = signalC(0)
    var captured: DeferredHandle = nil
    discard createRoot:
      effect [trigger]:
        let _ = trigger
        captured = runAfterPropagation(proc() {.closure.} = actionRan = true)
    actionRan = false
    trigger.set(1)
    check actionRan
    captured.cancel()
    captured.cancel()
    check captured.cancelled
    var nilHandle: DeferredHandle = nil
    nilHandle.cancel()
    check not nilHandle.cancelled
