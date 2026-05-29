## runAfterPropagation cancellation handles + scope-affine semantics (M-γ.2).
##
## The seam is no longer fire-once: every call returns a `DeferredHandle`
## that can be cancelled. When called inside a Scope, the handle is
## auto-cancelled by scope dispose — the substrate eliminates the
## "captured disposed flag" idiom that every mountWhen-style consumer
## would otherwise re-invent.

import std/unittest
import proptest
include intonaco/reactive_internal

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

  test "self-cancel mid-execution: action runs once; handle ends cancelled":
    # An action that cancels its OWN handle from inside its body. The
    # closure has already started executing, so the cancel can't un-fire
    # this invocation. Post-call, the handle reports cancelled — the
    # flag flip is observable but vestigial. Pins the substrate's
    # one-shot semantics: deferred actions are fire-once, so a mid-flight
    # cancel has no in-flight invocation to abort.
    var runCount = 0
    let trigger = signalC(0)
    var captured: DeferredHandle = nil
    discard createRoot:
      effect [trigger]:
        let _ = trigger
        # Hold the handle in a captured ref the closure can read. We
        # bind it via a closure-over-`captured` (a ref the test scope
        # also reads).
        captured = runAfterPropagation(proc() {.closure.} =
          inc runCount
          captured.cancel())   # self-cancel mid-body
    runCount = 0
    trigger.set(1)
    check runCount == 1          # the in-flight call wasn't aborted
    check captured.cancelled     # the flag did flip

suite "runAfterPropagation cancellation — properties":

  # Property: starting from a fresh handle, any number of cancel calls
  # leaves cancelled=true (monotonic latch). cancel is idempotent and
  # never resets the flag. Doubles as a regression guard against any
  # future change that adds a "re-arm" or "uncancel" semantic without
  # a corresponding API redesign.
  property "cancel is monotonic — N cancels still report cancelled":
    given n in integers(1, 20)
    let h = DeferredHandle()
    for _ in 0 ..< n:
      h.cancel()
    ensure h.cancelled

  # Property: when an action is enqueued under propagation and `k`
  # cancels are issued BEFORE the deferred batch drains, the action
  # runs iff k == 0. Independent of k > 0 — one cancel is enough.
  # Generated via signal-driven propagation so the action is actually
  # in gDeferred (not the synchronous outside-propagation path).
  property "any pre-drain cancel suppresses the action; zero cancels lets it run":
    given preCancels in integers(0, 5)
    var ran = 0
    var handles: seq[DeferredHandle] = @[]
    let trigger = signalC(0)
    discard createRoot:
      effect [trigger]:
        let _ = trigger
        let h = runAfterPropagation(proc() {.closure.} = inc ran)
        handles.add h
        for _ in 0 ..< preCancels:
          h.cancel()
    ran = 0
    handles.setLen(0)
    trigger.set(1)
    ensure (if preCancels == 0: ran == 1 else: ran == 0)
    ensure handles.len == 1
    ensure handles[0].cancelled == (preCancels > 0)
